{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
module Database where

import           Control.Monad (void)
import           Control.Monad.Logger (runStdoutLoggingT, MonadLogger, LoggingT, LogLevel(..))
import           Control.Monad.Reader
import           Data.ByteString.Char8 (pack, unpack)
import           Data.Int (Int64)
import           Data.Maybe (listToMaybe)
import           Database.Esqueleto (select, from, where_, (^.), val, (==.), on,
                                     InnerJoin(..), limit, orderBy, desc)
import           Database.Persist (get, insert, delete, entityVal, Entity)
import           Database.Persist.Sql (fromSqlKey, toSqlKey)
import           Database.Persist.Postgresql (ConnectionString, withPostgresqlConn, runMigration, SqlPersistT, PostgresConf(..))
import           Database.Redis (ConnectInfo, connect, Redis, runRedis, defaultConnectInfo, setex, del)
import qualified Database.Redis as Redis
import           Servant (ServantErr)
import           Control.Monad.Except (ExceptT, MonadError)
import           Schema


type PGInfo = ConnectionString
type RedisInfo = ConnectInfo

newtype AppMonadT m a = AppMonadT { unAppMonad :: ReaderT Config (ExceptT ServantErr m) a}
  deriving ( Functor
           , Applicative
           , Monad
           , MonadIO
           , MonadReader Config
           , MonadError ServantErr
           )
type App = AppMonadT IO

data Config = Config
  { pgInfo :: !ConnectionString
  , redisInfo :: !ConnectInfo
  }

postgresConf :: PostgresConf
postgresConf = PostgresConf
    { pgConnStr  = localConnString
      -- ^ The connection string.
    , pgPoolSize = 5
    }

defaultConfig :: Config
defaultConfig = Config
  { pgInfo = localConnString
  , redisInfo = defaultConnectInfo
  }


localConnString :: PGInfo
localConnString = "host=127.0.0.1 port=5432 user=postgres dbname=postgres"

logFilter :: a -> LogLevel -> Bool
logFilter _ LevelError     = True
logFilter _ LevelWarn      = True
logFilter _ LevelInfo      = True
logFilter _ LevelDebug     = False
logFilter _ (LevelOther _) = False

fetchPostgresConnection :: IO PGInfo
fetchPostgresConnection = return localConnString

fetchRedisConnection :: IO RedisInfo
fetchRedisConnection = return defaultConnectInfo

runAction :: PGInfo -> SqlPersistT (LoggingT IO) a -> IO a
runAction connectionString action =
  runStdoutLoggingT $ withPostgresqlConn connectionString $ \backend ->
    runReaderT action backend

runAction' :: (MonadReader Config m, MonadIO m) => SqlPersistT (LoggingT IO) a -> m a
runAction' action = do
  pgConnection <- asks pgInfo
  liftIO $ runStdoutLoggingT $ withPostgresqlConn pgConnection $ \backend ->
    runReaderT action backend

doMigrations :: SqlPersistT IO ()
doMigrations = runMigration migrateAll

migrateDB :: PGInfo -> IO ()
migrateDB connString = runAction connString $ runMigration migrateAll

fetchUserPG :: PGInfo -> Int64 -> IO (Maybe User)
fetchUserPG connString uid = runAction connString $ get (toSqlKey uid)

fetchUserPG' :: MonadIO m => Int64 -> AppMonadT m (Maybe User)
fetchUserPG' uid = runAction' $ get (toSqlKey uid)

createUserPG :: PGInfo -> User -> IO Int64
createUserPG connString user = fromSqlKey <$> runAction connString (insert user)

createUserPG' :: MonadIO m => User -> AppMonadT m Int64
createUserPG' user = fromSqlKey <$> runAction' (insert user)

deleteUserPG :: PGInfo -> Int64 -> IO()
deleteUserPG connString uid = runAction connString (delete userKey)
  where
    userKey :: Key User
    userKey = toSqlKey uid

deleteUserPG' :: MonadIO m => Int64 -> AppMonadT m ()
deleteUserPG' uid = runAction' (delete userKey)
  where
    userKey :: Key User
    userKey = toSqlKey uid
    
runRedisAction :: RedisInfo -> Redis a -> IO a
runRedisAction redisInfo action = do
  connection <- connect redisInfo
  runRedis connection action

runRedisAction' :: (MonadReader Config m, MonadIO m) => Redis a -> m a
runRedisAction' action = do
  info <- asks redisInfo
  connection <- liftIO $ connect info
  liftIO $ runRedis connection action

  
cacheUser :: RedisInfo -> Int64 -> User -> IO ()
cacheUser redisInfo uid user = runRedisAction redisInfo $ void $ setex (pack . show $ uid) 360 (pack .show $ user)

cacheUser' :: MonadIO m => Int64 -> User -> AppMonadT m ()
cacheUser' uid user = runRedisAction' $ void $ setex (pack . show $ uid) 360 (pack . show $ user)

deleteUserCache :: RedisInfo -> Int64 -> IO ()
deleteUserCache redisInfo uid = runRedisAction redisInfo $ void $ del [pack . show $ uid]

deleteUserCache' :: MonadIO m => Int64 -> AppMonadT m ()
deleteUserCache' uid = runRedisAction' $ void $ del [pack . show $ uid]

fetchUserRedis :: RedisInfo -> Int64 -> IO (Maybe User)
fetchUserRedis redisInfo uid = runRedisAction redisInfo $ do
  result <- Redis.get (pack . show $ uid)
  case result of
    Right (Just userString) -> return $ Just (read . unpack $ userString)
    _ -> return Nothing
    
 
fetchUserRedis' :: MonadIO m => Int64 -> AppMonadT m (Maybe User)
fetchUserRedis' uid = runRedisAction' $ do
  result <- Redis.get (pack . show $ uid)
  case result of
    Right (Just userString) -> return $ Just (read . unpack $ userString)
    _ -> return Nothing
  
createArticlePG :: PGInfo -> Article -> IO Int64
createArticlePG connString article = fromSqlKey <$> runAction connString (insert article)

createArticlePG' :: MonadIO m => Article -> AppMonadT m Int64
createArticlePG' article = fromSqlKey <$> runAction' (insert article)


fetchArticlePG :: PGInfo -> Int64 -> IO (Maybe Article)
fetchArticlePG connString aid = runAction connString selectAction
  where
    selectAction =
      fmap entityVal . listToMaybe <$>
      (select . from $ \articles -> do
         where_ (articles ^. ArticleId ==. val (toSqlKey aid))
         return articles)
         
fetchArticlePG' :: MonadIO m => Int64 -> AppMonadT m (Maybe Article)
fetchArticlePG' aid = runAction' selectAction
  where
    selectAction =
      fmap entityVal . listToMaybe <$>
      (select . from $ \articles -> do
         where_ (articles ^. ArticleId ==. val (toSqlKey aid))
         return articles)

fetchArticlesByAuthorPG :: PGInfo -> Int64  -> IO [Entity Article]
fetchArticlesByAuthorPG connString uid = runAction connString fetchAction
  where
    fetchAction = select . from $ \articles -> do
      where_ (articles ^. ArticleAuthorId ==. val (toSqlKey uid))
      return articles

fetchArticlesByAuthorPG' :: MonadIO m => Int64 -> AppMonadT m [Entity Article]
fetchArticlesByAuthorPG' uid = runAction' fetchAction
  where
    fetchAction = select . from $ \articles -> do
      where_ (articles ^. ArticleAuthorId ==. val (toSqlKey uid))
      return articles

fetchRecentArticlesPG :: PGInfo -> IO [(Entity User, Entity Article)]
fetchRecentArticlesPG connString = runAction connString fetchAction
  where
    fetchAction = select . from $ \(users `InnerJoin` articles) -> do
      on (users ^. UserId ==. articles ^. ArticleAuthorId)
      orderBy [desc (articles ^. ArticlePublishedTime)]
      limit 10
      return (users, articles)
      
fetchRecentArticlesPG' :: MonadIO m => AppMonadT m [(Entity User, Entity Article)]
fetchRecentArticlesPG' = runAction' fetchAction
  where
    fetchAction = select . from $ \(users `InnerJoin` articles) -> do
      on (users ^. UserId ==. articles ^. ArticleAuthorId)
      orderBy [desc (articles ^. ArticlePublishedTime)]
      limit 10
      return (users, articles)
      

deleteArticlePG :: PGInfo -> Int64 -> IO()
deleteArticlePG connString aid = runAction connString (delete articleKey)
  where
    articleKey :: Key Article
    articleKey = toSqlKey aid
    
deleteArticlePG' :: MonadIO m => Int64 -> AppMonadT m ()
deleteArticlePG' aid = runAction' $ delete (toSqlKey aid :: Key Article)