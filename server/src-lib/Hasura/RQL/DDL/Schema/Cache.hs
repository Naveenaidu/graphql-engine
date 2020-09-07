{-# LANGUAGE Arrows           #-}
{-# LANGUAGE OverloadedLabels #-}

{-| Top-level functions concerned specifically with operations on the schema cache, such as
rebuilding it from the catalog and incorporating schema changes. See the module documentation for
"Hasura.RQL.DDL.Schema" for more details.

__Note__: this module is __mutually recursive__ with other @Hasura.RQL.DDL.Schema.*@ modules, which
both define pieces of the implementation of building the schema cache and define handlers that
trigger schema cache rebuilds. -}
module Hasura.RQL.DDL.Schema.Cache
  ( RebuildableSchemaCache
  , MetadataStateResult(..)
  , lastBuiltSchemaCache
  , buildRebuildableSchemaCache
  , CacheRWT
  , runCacheRWT

  , withMetadataCheck
  ) where

import           Hasura.Prelude

import qualified Data.Environment                         as Env
import qualified Data.HashMap.Strict.Extended             as M
import qualified Data.HashSet                             as HS
import qualified Data.Text                                as T
import qualified Database.PG.Query                        as Q

import           Control.Arrow.Extended
import           Control.Lens                             hiding ((.=))
import           Control.Monad.Unique
import           Data.Aeson
import           Data.List                                (nub)

import qualified Hasura.Incremental                       as Inc

import           Hasura.Db
import           Hasura.GraphQL.Execute.Types
import           Hasura.GraphQL.Schema                    (buildGQLContext)
import           Hasura.RQL.DDL.Action
import           Hasura.RQL.DDL.ComputedField
import           Hasura.RQL.DDL.CustomTypes
import           Hasura.RQL.DDL.Deps
import           Hasura.RQL.DDL.EventTrigger
import           Hasura.RQL.DDL.RemoteSchema
import           Hasura.RQL.DDL.ScheduledTrigger
import           Hasura.RQL.DDL.Schema.Cache.Common
import           Hasura.RQL.DDL.Schema.Cache.Dependencies
import           Hasura.RQL.DDL.Schema.Cache.Fields
import           Hasura.RQL.DDL.Schema.Cache.Permission
import           Hasura.RQL.DDL.Schema.Catalog
import           Hasura.RQL.DDL.Schema.Diff
import           Hasura.RQL.DDL.Schema.Function
import           Hasura.RQL.DDL.Schema.Table
import           Hasura.RQL.DDL.Utils                     (clearHdbViews)
import           Hasura.RQL.Types                         hiding (tmTable)
import           Hasura.RQL.Types.Catalog
import           Hasura.Server.Version                    (HasVersion)
import           Hasura.SQL.Types

buildRebuildableSchemaCache
  :: (HasVersion, MonadIO m, MonadUnique m, MonadTx m, HasHttpManager m, HasSQLGenCtx m, MonadMetadata m)
  => Env.Environment
  -> m (RebuildableSchemaCache m)
buildRebuildableSchemaCache env = do
  metadata <- fetchMetadata
  catalogMetadata <- buildCatalogMetadata metadata
  result <- flip runReaderT CatalogSync $
    Inc.build (buildSchemaCacheRule env) (catalogMetadata, initialInvalidationKeys)
  pure $ RebuildableSchemaCache (Inc.result result) initialInvalidationKeys (Inc.rebuildRule result)

newtype CacheRWT m a
  -- The CacheInvalidations component of the state could actually be collected using WriterT, but
  -- WriterT implementations prior to transformers-0.5.6.0 (which added
  -- Control.Monad.Trans.Writer.CPS) are leaky, and we don’t have that yet.
  = CacheRWT (StateT (RebuildableSchemaCache m, CacheInvalidations) m a)
  deriving
    ( Functor, Applicative, Monad, MonadIO, MonadUnique, MonadReader r, MonadError e, MonadTx
    , UserInfoM, HasHttpManager, HasSQLGenCtx, HasSystemDefined, MonadMetadata)

runCacheRWT
  :: Functor m
  => RebuildableSchemaCache m -> CacheRWT m a -> m (a, RebuildableSchemaCache m, CacheInvalidations)
runCacheRWT cache (CacheRWT m) =
  runStateT m (cache, mempty) <&> \(v, (newCache, invalidations)) -> (v, newCache, invalidations)

instance MonadTrans CacheRWT where
  lift = CacheRWT . lift

instance (Monad m) => SourceLocalM (CacheRWT m)
instance (Monad m) => TableCoreInfoRM (CacheRWT m)
instance (Monad m) => CacheRM (CacheRWT m) where
  askSchemaCache = CacheRWT $ gets (lastBuiltSchemaCache . fst)

instance (MonadIO m, MonadTx m, MonadMetadata m) => CacheRWM (CacheRWT m) where
  buildSchemaCacheWithOptions buildReason invalidations metadataModifier = CacheRWT do
    (RebuildableSchemaCache _ invalidationKeys rule, oldInvalidations) <- get
    let newInvalidationKeys = invalidateKeys invalidations invalidationKeys
    metadata <- fetchMetadata
    let modifiedMetadata = (unMetadataModifier metadataModifier) metadata
    catalogMetadata <- buildCatalogMetadata modifiedMetadata
    result <- lift $ flip runReaderT buildReason $
      Inc.build rule (catalogMetadata, newInvalidationKeys)
    let schemaCache = Inc.result result
        prunedInvalidationKeys = pruneInvalidationKeys schemaCache newInvalidationKeys
        !newCache = RebuildableSchemaCache schemaCache prunedInvalidationKeys (Inc.rebuildRule result)
        !newInvalidations = oldInvalidations <> invalidations
    when (metadata /= modifiedMetadata) $ updateMetadata modifiedMetadata
    put (newCache, newInvalidations)
    where
      -- Prunes invalidation keys that no longer exist in the schema to avoid leaking memory by
      -- hanging onto unnecessary keys.
      pruneInvalidationKeys schemaCache = over ikRemoteSchemas $ M.filterWithKey \name _ ->
        -- see Note [Keep invalidation keys for inconsistent objects]
        name `elem` getAllRemoteSchemas schemaCache

buildSchemaCacheRule
  -- Note: by supplying BuildReason via MonadReader, it does not participate in caching, which is
  -- what we want!
  :: ( HasVersion, ArrowChoice arr, Inc.ArrowDistribute arr, Inc.ArrowCache m arr
     , MonadIO m, MonadUnique m, MonadTx m
     , MonadReader BuildReason m, HasHttpManager m, HasSQLGenCtx m )
  => Env.Environment
  -> (CatalogMetadata, InvalidationKeys) `arr` SchemaCache
buildSchemaCacheRule env = proc (catalogMetadata, invalidationKeys) -> do
  invalidationKeysDep <- Inc.newDependency -< invalidationKeys

  -- Step 1: Process metadata and collect dependency information.
  (outputs, collectedInfo) <-
    runWriterA (buildAndCollectInfo defaultSource) -< (catalogMetadata, invalidationKeysDep)
  let (inconsistentObjects, unresolvedDependencies) = partitionCollectedInfo collectedInfo

  -- Step 2: Resolve dependency information and drop dangling dependents.
  (resolvedOutputs, dependencyInconsistentObjects, resolvedDependencies) <-
    resolveDependencies -< (outputs, unresolvedDependencies)

  -- Step 3: Build the GraphQL schema.
  (gqlContext, gqlSchemaInconsistentObjects) <- runWriterA buildGQLContext -<
    ( QueryHasura
    , (_boTables    resolvedOutputs)
    , (_boFunctions resolvedOutputs)
    , (_boRemoteSchemas resolvedOutputs)
    , (_boActions resolvedOutputs)
    , (_actNonObjects $ _boCustomTypes resolvedOutputs)
    )

  -- Step 4: Build the relay GraphQL schema
  (relayContext, relaySchemaInconsistentObjects) <- runWriterA buildGQLContext -<
    ( QueryRelay
    , (_boTables    resolvedOutputs)
    , (_boFunctions resolvedOutputs)
    , (_boRemoteSchemas resolvedOutputs)
    , (_boActions resolvedOutputs)
    , (_actNonObjects $ _boCustomTypes resolvedOutputs)
    )

  returnA -< SchemaCache
    { scPostgres = M.singleton defaultSource $ PGSourceSchemaCache (_boTables resolvedOutputs) (_boFunctions resolvedOutputs)
    , scActions = _boActions resolvedOutputs
    -- TODO this is not the right value: we should track what part of the schema
    -- we can stitch without consistencies, I think.
    , scRemoteSchemas = fmap fst (_boRemoteSchemas resolvedOutputs) -- remoteSchemaMap
    , scAllowlist = _boAllowlist resolvedOutputs
    -- , scCustomTypes = _boCustomTypes resolvedOutputs
    , scGQLContext = fst gqlContext
    , scUnauthenticatedGQLContext = snd gqlContext
    , scRelayContext = fst relayContext
    , scUnauthenticatedRelayContext = snd relayContext
    -- , scGCtxMap = gqlSchema
    -- , scDefaultRemoteGCtx = remoteGQLSchema
    , scDepMap = resolvedDependencies
    , scCronTriggers = _boCronTriggers resolvedOutputs
    , scInconsistentObjs =
           inconsistentObjects
        <> dependencyInconsistentObjects
        <> toList gqlSchemaInconsistentObjects
        <> toList relaySchemaInconsistentObjects
    }
  where
    buildAndCollectInfo
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, Inc.ArrowCache m arr
         , ArrowWriter (Seq CollectedInfo) arr, MonadIO m, MonadUnique m, MonadTx m, MonadReader BuildReason m
         , HasHttpManager m, HasSQLGenCtx m )
      => SourceName -> (CatalogMetadata, Inc.Dependency InvalidationKeys) `arr` BuildOutputs
    buildAndCollectInfo source = proc (catalogMetadata, invalidationKeys) -> do
      let CatalogMetadata tables relationships permissions
            eventTriggers remoteSchemas functions allowlistDefs
            computedFields catalogCustomTypes actions remoteRelationships
            cronTriggers = catalogMetadata

      -- tables
      tableRawInfos <- buildTableCache -< (tables, Inc.selectD #_ikMetadata invalidationKeys)

      -- remote schemas
      let remoteSchemaInvalidationKeys = Inc.selectD #_ikRemoteSchemas invalidationKeys
      remoteSchemaMap <- buildRemoteSchemas -< (remoteSchemaInvalidationKeys, remoteSchemas)

      -- relationships and computed fields
      let relationshipsByTable = M.groupOn _crTable relationships
          computedFieldsByTable = M.groupOn (_afcTable . _cccComputedField) computedFields
          remoteRelationshipsByTable = M.groupOn rtrTable remoteRelationships
      tableCoreInfos <- (tableRawInfos >- returnA)
        >-> (\info -> (info, relationshipsByTable) >- alignExtraTableInfo (mkRelationshipMetadataObject source))
        >-> (\info -> (info, computedFieldsByTable) >- alignExtraTableInfo mkComputedFieldMetadataObject)
        >-> (\info -> (info, remoteRelationshipsByTable) >- alignExtraTableInfo mkRemoteRelationshipMetadataObject)
        >-> (| Inc.keyed (\_ (((tableRawInfo, tableRelationships), tableComputedFields), tableRemoteRelationships) -> do
                 let columns = _tciFieldInfoMap tableRawInfo
                 allFields <- addNonColumnFields source -<
                   (tableRawInfos, columns, M.map fst remoteSchemaMap, tableRelationships, tableComputedFields, tableRemoteRelationships)
                 returnA -< (tableRawInfo { _tciFieldInfoMap = allFields })) |)

      -- permissions and event triggers
      tableCoreInfosDep <- Inc.newDependency -< tableCoreInfos
      tableCache <- (tableCoreInfos >- returnA)
        >-> (\info -> (info, M.groupOn _cpTable permissions) >- alignExtraTableInfo (mkPermissionMetadataObject source))
        >-> (\info -> (info, M.groupOn _cetTable eventTriggers) >- alignExtraTableInfo mkEventTriggerMetadataObject)
        >-> (| Inc.keyed (\_ ((tableCoreInfo, tablePermissions), tableEventTriggers) -> do
                 let tableName = _tciName tableCoreInfo
                     tableFields = _tciFieldInfoMap tableCoreInfo
                 permissionInfos <- buildTablePermissions source -<
                   (tableCoreInfosDep, tableName, tableFields, HS.fromList tablePermissions)
                 eventTriggerInfos <- buildTableEventTriggers -< (tableCoreInfo, tableEventTriggers)
                 returnA -< TableInfo
                   { _tiCoreInfo = tableCoreInfo
                   , _tiRolePermInfoMap = permissionInfos
                   , _tiEventTriggerInfoMap = eventTriggerInfos
                   }) |)

      -- sql functions
      functionCache <- (mapFromL _cfFunction functions >- returnA)
        >-> (| Inc.keyed (\_ (CatalogFunction qf systemDefined config funcDefs) -> do
                 let definition = toJSON $ TrackFunction qf
                     metadataObject = MetadataObject (MOFunction qf) definition
                     schemaObject = SOFunction qf
                     addFunctionContext e = "in function " <> qf <<> ": " <> e
                 (| withRecordInconsistency (
                    (| modifyErrA (do
                         rawfi <- bindErrorA -< handleMultipleFunctions qf funcDefs
                         (fi, dep) <- bindErrorA -< mkFunctionInfo qf systemDefined config rawfi
                         recordDependencies -< (metadataObject, schemaObject, [dep])
                         returnA -< fi)
                    |) addFunctionContext)
                  |) metadataObject) |)
        >-> (\infos -> M.catMaybes infos >- returnA)

      -- allow list
      let allowList = allowlistDefs
            & concatMap _cdQueries
            & map (queryWithoutTypeNames . getGQLQuery . _lqQuery)
            & HS.fromList

      -- custom types
      let CatalogCustomTypes customTypes pgScalars = catalogCustomTypes
      maybeResolvedCustomTypes <-
        (| withRecordInconsistency
             (bindErrorA -< resolveCustomTypes tableCache customTypes pgScalars)
         |) (MetadataObject MOCustomTypes $ toJSON customTypes)

      -- -- actions
      (actionCache, annotatedCustomTypes) <- case maybeResolvedCustomTypes of
        Just resolvedCustomTypes -> do
          actionCache' <- buildActions -< ((resolvedCustomTypes, pgScalars), actions)
          returnA -< (actionCache', resolvedCustomTypes)

        -- If the custom types themselves are inconsistent, we can’t really do
        -- anything with actions, so just mark them all inconsistent.
        Nothing -> do
          recordInconsistencies -< ( map mkActionMetadataObject actions
                                   , "custom types are inconsistent" )
          returnA -< (M.empty, emptyAnnotatedCustomTypes)

      cronTriggersMap <- buildCronTriggers -< ((),cronTriggers)

      returnA -< BuildOutputs
        { _boTables = tableCache
        , _boFunctions = functionCache
        , _boActions = actionCache
        , _boRemoteSchemas = remoteSchemaMap
        , _boAllowlist = allowList
        , _boCustomTypes = annotatedCustomTypes
        , _boCronTriggers = cronTriggersMap
        }

    mkEventTriggerMetadataObject (CatalogEventTrigger qt trn configuration) =
      let objectId = MOTableObj qt $ MTOTrigger trn
          definition = object ["table" .= qt, "configuration" .= configuration]
      in MetadataObject objectId definition

    mkCronTriggerMetadataObject catalogCronTrigger =
      let definition = toJSON catalogCronTrigger
      in MetadataObject (MOCronTrigger (_cctName catalogCronTrigger))
                        definition

    mkActionMetadataObject (ActionMetadata name comment defn _) =
      MetadataObject (MOAction name) (toJSON $ CreateAction name defn comment)

    mkRemoteSchemaMetadataObject remoteSchema =
      MetadataObject (MORemoteSchema (_arsqName remoteSchema)) (toJSON remoteSchema)

    -- Given a map of table info, “folds in” another map of information, accumulating inconsistent
    -- metadata objects for any entries in the second map that don’t appear in the first map. This
    -- is used to “line up” the metadata for relationships, computed fields, permissions, etc. with
    -- the tracked table info.
    alignExtraTableInfo
      :: forall a b arr
       . (ArrowChoice arr, Inc.ArrowDistribute arr, ArrowWriter (Seq CollectedInfo) arr)
      => (b -> MetadataObject)
      -> ( M.HashMap QualifiedTable a
         , M.HashMap QualifiedTable [b]
         ) `arr` M.HashMap QualifiedTable (a, [b])
    alignExtraTableInfo mkMetadataObject = proc (baseInfo, extraInfo) -> do
      combinedInfo <-
        (| Inc.keyed (\tableName infos -> combine -< (tableName, infos))
        |) (align baseInfo extraInfo)
      returnA -< M.catMaybes combinedInfo
      where
        combine :: (QualifiedTable, These a [b]) `arr` Maybe (a, [b])
        combine = proc (tableName, infos) -> case infos of
          This  base        -> returnA -< Just (base, [])
          These base extras -> returnA -< Just (base, extras)
          That       extras -> do
            let errorMessage = "table " <> tableName <<> " does not exist"
            recordInconsistencies -< (map mkMetadataObject extras, errorMessage)
            returnA -< Nothing

    buildTableEventTriggers
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, ArrowWriter (Seq CollectedInfo) arr
         , Inc.ArrowCache m arr, MonadTx m, MonadReader BuildReason m, HasSQLGenCtx m )
      => (TableCoreInfo, [CatalogEventTrigger]) `arr` EventTriggerInfoMap
    buildTableEventTriggers = buildInfoMap _cetName mkEventTriggerMetadataObject buildEventTrigger
      where
        buildEventTrigger = proc (tableInfo, eventTrigger) -> do
          let CatalogEventTrigger qt trn configuration = eventTrigger
              metadataObject = mkEventTriggerMetadataObject eventTrigger
              schemaObjectId = SOTableObj qt $ TOTrigger trn
              addTriggerContext e = "in event trigger " <> trn <<> ": " <> e
          (| withRecordInconsistency (
             (| modifyErrA (do
                  etc <- bindErrorA -< decodeValue configuration
                  (info, dependencies) <- bindErrorA -< subTableP2Setup env qt etc
                  let tableColumns = M.mapMaybe (^? _FIColumn) (_tciFieldInfoMap tableInfo)
                  recreateViewIfNeeded -< (qt, tableColumns, trn, etcDefinition etc)
                  recordDependencies -< (metadataObject, schemaObjectId, dependencies)
                  returnA -< info)
             |) (addTableContext qt . addTriggerContext))
           |) metadataObject

        recreateViewIfNeeded = Inc.cache $
          arrM \(tableName, tableColumns, triggerName, triggerDefinition) -> do
            buildReason <- ask
            when (buildReason == CatalogUpdate) $ do
              liftTx $ delTriggerQ triggerName -- executes DROP IF EXISTS.. sql
              mkAllTriggersQ triggerName tableName (M.elems tableColumns) triggerDefinition

    buildCronTriggers
      :: ( ArrowChoice arr
         , Inc.ArrowDistribute arr
         , ArrowWriter (Seq CollectedInfo) arr
         , Inc.ArrowCache m arr
         , MonadTx m)
      => ((),[CatalogCronTrigger])
         `arr` HashMap TriggerName CronTriggerInfo
    buildCronTriggers = buildInfoMap _cctName mkCronTriggerMetadataObject buildCronTrigger
      where
        buildCronTrigger = proc (_,cronTrigger) -> do
          let triggerName = triggerNameToTxt $ _cctName cronTrigger
              addCronTriggerContext e = "in cron trigger " <> triggerName <> ": " <> e
          (| withRecordInconsistency (
            (| modifyErrA (bindErrorA -< resolveCronTrigger env cronTrigger)
             |) addCronTriggerContext)
           |) (mkCronTriggerMetadataObject cronTrigger)

    buildActions
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, Inc.ArrowCache m arr
         , ArrowWriter (Seq CollectedInfo) arr)
      => ( (AnnotatedCustomTypes, HashSet PGScalarType)
         , [ActionMetadata]
         ) `arr` HashMap ActionName ActionInfo
    buildActions = buildInfoMap _amName mkActionMetadataObject buildAction
      where
        buildAction = proc ((resolvedCustomTypes, pgScalars), action) -> do
          let ActionMetadata name comment def actionPermissions = action
              addActionContext e = "in action " <> name <<> "; " <> e
          (| withRecordInconsistency (
             (| modifyErrA (do
                  (resolvedDef, outObject) <- liftEitherA <<< bindA -<
                    runExceptT $ resolveAction env resolvedCustomTypes def pgScalars
                  let permissionInfos =
                        map (uncurry ActionPermissionInfo . (_apmRole &&& _apmComment)) actionPermissions
                      permissionMap = mapFromL _apiRole permissionInfos
                  returnA -< ActionInfo name outObject resolvedDef permissionMap comment)
              |) addActionContext)
           |) (mkActionMetadataObject action)

    buildRemoteSchemas
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, ArrowWriter (Seq CollectedInfo) arr
         , Inc.ArrowCache m arr , MonadIO m, MonadUnique m, HasHttpManager m )
      => ( Inc.Dependency (HashMap RemoteSchemaName Inc.InvalidationKey)
         , [AddRemoteSchemaQuery]
         ) `arr` HashMap RemoteSchemaName (RemoteSchemaCtx, MetadataObject)
    buildRemoteSchemas =
      buildInfoMapPreservingMetadata _arsqName mkRemoteSchemaMetadataObject buildRemoteSchema
      where
        -- We want to cache this call because it fetches the remote schema over HTTP, and we don’t
        -- want to re-run that if the remote schema definition hasn’t changed.
        buildRemoteSchema = Inc.cache proc (invalidationKeys, remoteSchema) -> do
          Inc.dependOn -< Inc.selectKeyD (_arsqName remoteSchema) invalidationKeys
          (| withRecordInconsistency (liftEitherA <<< bindA -<
               runExceptT $ addRemoteSchemaP2Setup env remoteSchema)
           |) (mkRemoteSchemaMetadataObject remoteSchema)

-- | @'withMetadataCheck' cascade action@ runs @action@ and checks if the schema changed as a
-- result. If it did, it checks to ensure the changes do not violate any integrity constraints, and
-- if not, incorporates them into the schema cache.
withMetadataCheck
  :: (MonadTx m, CacheRWM m, HasSQLGenCtx m) => SourceName -> Bool -> m a -> m a
withMetadataCheck source cascade action = do
  -- Drop hdb_views so no interference is caused to the sql query
  liftTx $ Q.catchE defaultTxErrorHandler clearHdbViews
  sc <- askSchemaCache
  let sourceTables = maybe mempty _pcTables $ M.lookup source $ scPostgres sc
      existingFunctions = maybe mempty _pcFunctions $ M.lookup source $ scPostgres sc
      existingInconsistentObjs = scInconsistentObjs sc

  -- Get the metadata before the sql query, everything, need to filter this
  (oldTableMeta, oldFunctionMeta) <- fetchMeta sourceTables existingFunctions
  -- oldMetaU <- liftTx $ Q.catchE defaultTxErrorHandler fetchTableMeta
  -- oldFuncMetaU <- liftTx $ Q.catchE defaultTxErrorHandler fetchFunctionMeta

  -- Run the action
  res <- action

  -- Get the metadata after the sql query
  (newTableMeta, newFunctionMeta) <- fetchMeta sourceTables existingFunctions

  let existingTablesOldMeta = filter (flip M.member sourceTables . tmTable) oldTableMeta
      schemaDiff = getSchemaDiff existingTablesOldMeta newTableMeta
      FunctionDiff droppedFuncs alteredFuncs = getFuncDiff oldFunctionMeta newFunctionMeta
      overloadedFuncs = getOverloadedFuncs (M.keys existingFunctions) newFunctionMeta

  -- Old Code TODO: Clean up
  -- newMeta <- liftTx $ Q.catchE defaultTxErrorHandler fetchTableMeta
  -- newFuncMeta <- liftTx $ Q.catchE defaultTxErrorHandler fetchFunctionMeta
  -- sc <- askSchemaCache
  -- let existingInconsistentObjs = scInconsistentObjs sc
  --     sourceTables = maybe mempty _pcTables $ M.lookup source $ scPostgres sc
  --     sourceTableNames = M.keys sourceTables
  --     oldMeta = flip filter oldMetaU $ \tm -> tmTable tm `elem` sourceTableNames
  --     schemaDiff = getSchemaDiff oldMeta newMeta
  --     existingFuncs = M.keys $ maybe mempty _pcFunctions $ M.lookup source $ scPostgres sc
  --     oldFuncMeta = flip filter oldFuncMetaU $ \fm -> fmFunction fm `elem` existingFuncs
  --     FunctionDiff droppedFuncs alteredFuncs = getFuncDiff oldFuncMeta newFuncMeta
  --     overloadedFuncs = getOverloadedFuncs existingFuncs newFuncMeta

  -- Do not allow overloading functions
  unless (null overloadedFuncs) $
    throw400 NotSupported $ "the following tracked function(s) cannot be overloaded: "
    <> reportFuncs overloadedFuncs

  indirectDeps <- getSchemaChangeDeps schemaDiff

  -- Report back with an error if cascade is not set
  when (indirectDeps /= [] && not cascade) $ reportDepsExt indirectDeps []

  metadataUpdater <- execWriterT $ do
    -- Purge all the indirect dependents from state
    mapM_ (purgeDependentObject source >=> tell) indirectDeps

    -- Purge all dropped functions
    let purgedFuncs = flip mapMaybe indirectDeps $ \dep ->
          case dep of
            SOFunction qf -> Just qf
            _             -> Nothing

    forM_ (droppedFuncs \\ purgedFuncs) $ \qf -> do
      tell $ dropFunctionInMetadata source qf

    -- Process altered functions
    forM_ alteredFuncs $ \(qf, newTy) -> do
      when (newTy == FTVOLATILE) $
        throw400 NotSupported $
        "type of function " <> qf <<> " is altered to \"VOLATILE\" which is not supported now"

    -- update the schema cache and hdb_catalog with the changes
    processSchemaChanges sourceTables schemaDiff

  buildSchemaCache metadataUpdater
  postSc <- askSchemaCache

  -- Recreate event triggers in hdb_views
  forM_ (M.elems sourceTables) $ \(TableInfo coreInfo _ eventTriggers) -> do
          let table = _tciName coreInfo
              columns = getCols $ _tciFieldInfoMap coreInfo
          forM_ (M.toList eventTriggers) $ \(triggerName, eti) -> do
            let opsDefinition = etiOpsDef eti
            mkAllTriggersQ triggerName table columns opsDefinition

  let currentInconsistentObjs = scInconsistentObjs postSc
  checkNewInconsistentMeta existingInconsistentObjs currentInconsistentObjs

  return res
  where
    reportFuncs = T.intercalate ", " . map dquoteTxt

    processSchemaChanges
      :: ( MonadError QErr m
         , CacheRM m
         , MonadWriter MetadataModifier m
         )
      => TableCache -> SchemaDiff -> m ()
    processSchemaChanges sourceTables schemaDiff = do
      -- Purge the dropped tables
      forM_ droppedTables $
        \tn -> tell $ MetadataModifier $ metaSources.ix source.smTables %~ M.delete tn

      for_ alteredTables $ \(oldQtn, tableDiff) -> do
        ti <- case M.lookup oldQtn sourceTables of
          Just ti -> return ti
          Nothing -> throw500 $ "old table metadata not found in cache : " <>> oldQtn
        processTableChanges source (_tiCoreInfo ti) tableDiff
      where
        SchemaDiff droppedTables alteredTables = schemaDiff

    checkNewInconsistentMeta
      :: (QErrM m)
      => [InconsistentMetadata] -> [InconsistentMetadata] -> m ()
    checkNewInconsistentMeta originalInconsMeta currentInconsMeta =
      unless (null newInconsistentObjects) $
        throwError (err500 Unexpected "cannot continue due to newly found inconsistent metadata")
          { qeInternal = Just $ toJSON newInconsistentObjects }
      where
        diffInconsistentObjects = M.difference `on` groupInconsistentMetadataById
        newInconsistentObjects = nub $ concatMap toList $
          M.elems (currentInconsMeta `diffInconsistentObjects` originalInconsMeta)

{- Note [Keep invalidation keys for inconsistent objects]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
After building the schema cache, we prune InvalidationKeys for objects
that no longer exist in the schema to avoid leaking memory for objects
that have been dropped. However, note that we *don’t* want to drop
keys for objects that are simply inconsistent!

Why? The object is still in the metadata, so next time we reload it,
we’ll reprocess that object. We want to reuse the cache if its
definition hasn’t changed, but if we dropped the invalidation key, it
will incorrectly be reprocessed (since the invalidation key changed
from present to absent). -}
