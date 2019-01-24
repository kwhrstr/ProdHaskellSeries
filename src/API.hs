{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
module API where

import           Control.Monad.IO.Class (liftIO, MonadIO)
import           Control.Monad.Except (throwError)
import           Data.Int (Int64)
import           Data.Proxy
import           Database.Persist(Key, Entity)
import           Servant.API
import           Servant.Client
import           Servant.Server
import           Network.Wai.Handler.Warp (run)
import           Control.Monad.Reader

import           Database
import           Schema

type UsersAPI = "users" :> Capture "userid" Int64 :> Get '[JSON] User :<|>
                "users" :> ReqBody '[JSON] User :> Post '[JSON] Int64
                
type ArticleAPI = "articles" :> Capture "articleid" Int64 :> Get '[JSON] Article :<|>
                  "articles" :> ReqBody '[JSON] Article :> Post '[JSON] Int64 :<|>
                  "articles" :> "author" :> Capture "authorid" Int64 :> Get '[JSON] [Entity Article] :<|>
                  "articles" :> "recent" :> Get '[JSON] [(Entity User, Entity Article)]

type FullAPI = UsersAPI :<|> ArticleAPI


fullAPI :: Proxy FullAPI
fullAPI = Proxy


fetchUsersHandler :: PGInfo -> RedisInfo -> Int64 -> Handler User
fetchUsersHandler pgInfo redisInfo uid = do
  maybeCachedUser <- liftIO $ fetchUserRedis redisInfo uid
  case maybeCachedUser of
    Just user -> return user
    Nothing -> do
      maybeUser <- liftIO $ fetchUserPG pgInfo uid
      case maybeUser of
        Just user -> liftIO (cacheUser redisInfo uid user) >> return user
        Nothing -> throwError err401 {errBody = "Could not find user with that ID"}
        
fetchUsers' :: MonadIO m => Int64 -> AppMonadT m User
fetchUsers' uid = do
  maybeCachedUser <- fetchUserRedis' uid
  case maybeCachedUser of
    Just user -> return user
    Nothing -> do
      maybeUser <- fetchUserPG' uid
      case maybeUser of
        Just user -> cacheUser' uid user >> return user
        Nothing -> throwError err401 { errBody = "Could not find user with that ID"}
        
        
createUserHandler :: PGInfo -> User -> Handler Int64
createUserHandler pgInfo user = liftIO $ createUserPG pgInfo user

createUser' :: MonadIO m => User -> AppMonadT m Int64
createUser' = createUserPG'

usersServer :: PGInfo -> RedisInfo -> Server UsersAPI
usersServer pgInfo redisInfo =
  fetchUsersHandler pgInfo redisInfo :<|>
  createUserHandler pgInfo
  
usersServer' :: MonadIO m => ServerT UsersAPI (AppMonadT m)
usersServer' = fetchUsers' :<|> createUser'


fetchArticleHandler :: PGInfo -> Int64 -> Handler Article
fetchArticleHandler pgInfo aid = do
  maybeArticle <- liftIO $ fetchArticlePG pgInfo aid
  case maybeArticle of
    Just article -> return article
    Nothing -> throwError err401{ errBody = "could not find article with that ID" }
    

fetchArticle' :: MonadIO m => Int64 -> AppMonadT m Article
fetchArticle' aid = do
  maybeArticle <- fetchArticlePG' aid
  case maybeArticle of
    Just article -> return article
    Nothing -> throwError err401 {errBody = "could not find article with that ID"}
    

createArticleHandler :: PGInfo -> Article -> Handler Int64
createArticleHandler pgInfo aid = liftIO $ createArticlePG pgInfo aid

createArticle' :: MonadIO m => Article -> AppMonadT m Int64
createArticle' = createArticlePG'

fetchArticlesByAuthorHandler :: PGInfo -> Int64 -> Handler [Entity Article]
fetchArticlesByAuthorHandler pgInfo uid = liftIO $ fetchArticlesByAuthorPG pgInfo uid

fetchArticlesByAuthor' :: MonadIO m => Int64 -> AppMonadT m [Entity Article]
fetchArticlesByAuthor' = fetchArticlesByAuthorPG'

fetchRecentArticlesHandler :: PGInfo -> Handler [(Entity User, Entity Article)]
fetchRecentArticlesHandler pgInfo = liftIO $ fetchRecentArticlesPG pgInfo

fetchRecentArticles' :: MonadIO m => AppMonadT m [(Entity User, Entity Article)]
fetchRecentArticles' = fetchRecentArticlesPG'

articlesServer :: PGInfo  -> Server ArticleAPI
articlesServer pgInfo  =
  fetchArticleHandler pgInfo  :<|>
  createArticleHandler pgInfo :<|>
  fetchArticlesByAuthorHandler pgInfo :<|>
  fetchRecentArticlesHandler pgInfo
  
articlesServer' :: MonadIO m => ServerT ArticleAPI (AppMonadT m)
articlesServer' =
  fetchArticle' :<|>
  createArticle' :<|>
  fetchArticlesByAuthor' :<|>
  fetchRecentArticles'


fullServer :: PGInfo -> RedisInfo -> Server FullAPI
fullServer pgInfo redisInfo = usersServer pgInfo redisInfo :<|>
                              articlesServer pgInfo

fullServer' :: MonadIO m => ServerT FullAPI (AppMonadT m)
fullServer' = usersServer' :<|> articlesServer'

convertApp :: Config -> App a -> Handler a
convertApp cfg appt = Handler $ runReaderT (unAppMonad appt) cfg


appToServer :: Config -> Server FullAPI
appToServer cfg = hoistServer fullAPI (convertApp cfg) fullServer'

runServer :: IO ()
runServer = do
  pgInfo <- fetchPostgresConnection
  redisInfo <- fetchRedisConnection
  run 8000 (serve fullAPI $ fullServer pgInfo redisInfo)

fullApp :: Config -> Application
fullApp cfg = serve fullAPI $ appToServer cfg

runServer' :: IO ()
runServer' = run 8000 $ fullApp defaultConfig


fetchUserClient :: Int64 -> ClientM User
createUserClient :: User -> ClientM Int64
fetchArticleClient :: Int64 -> ClientM Article
createArticleClient :: Article -> ClientM Int64
fetchArticlesByAuthorClient :: Int64 -> ClientM [Entity Article]
fetchRecentArticlesClient :: ClientM [(Entity User, Entity Article)]
( fetchUserClient             :<|>
  createUserClient )           = client (Proxy :: Proxy UsersAPI)
( fetchArticleClient          :<|>
  createArticleClient         :<|>
  fetchArticlesByAuthorClient :<|>
  fetchRecentArticlesClient )  = client (Proxy :: Proxy ArticleAPI)
























