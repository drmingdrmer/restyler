{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Restyler.Main
    ( restylerMain
    ) where

import Restyler.Prelude

import qualified Data.Yaml as Yaml
import Restyler.App
import Restyler.Model.Comment
import Restyler.Model.Config
import Restyler.Model.PullRequest
import Restyler.Model.PullRequest.Restyled
import Restyler.Model.PullRequest.Status
import Restyler.Model.PullRequestSpec
import Restyler.Model.RemoteFile
import Restyler.Model.Restyler
import Restyler.Model.Restyler.Run

restylerMain :: (HasCallStack, MonadApp m) => m ()
restylerMain = do
    unlessM configEnabled $ exitWithInfo "Restyler disabled by config"
    logIntentions

    remoteFiles <- asks $ cRemoteFiles . appConfig
    logInfoN $ "Fetching " <> tshow (length remoteFiles) <> " remote file(s)"
    for_ remoteFiles $ \RemoteFile {..} -> downloadFile (getUrl rfUrl) rfPath

    result <- restyle
    logDebugN $ "Restylers ran: " <> tshow (map rName $ rrRestylersRan result)
    logDebugN $ "Paths restyled: " <> tshow (rrChangedPaths result)

    unless (wasRestyled result) $ do
        clearRestyledComments
        closeRestyledPullRequest
        sendPullRequestStatus NoDifferencesStatus
        exitWithInfo "No style differences found"

    whenM isAutoPush $ do
        updateOriginalPullRequest
        exitWithInfo "Pushed to original PR"

    mRestyledPr <- asks appRestyledPullRequest
    restyledUrl <- case mRestyledPr of
        Just restyledPr -> do
            updateRestyledPullRequest
            pure $ simplePullRequestHtmlUrl restyledPr
        Nothing -> do
            restyledPr <- createRestyledPullRequest $ rrRestylersRan result
            whenM commentsEnabled $ leaveRestyledComment restyledPr
            pure $ pullRequestHtmlUrl restyledPr

    sendPullRequestStatus $ DifferencesStatus restyledUrl
    logInfoN "Restyling successful"

logIntentions :: MonadApp m => m ()
logIntentions = do
    App {..} <- ask
    logInfoN $ "Restyling " <> showSpec (pullRequestSpec appPullRequest)
    logDebugN $ "Resolved configuration\n" <> decodeUtf8 (Yaml.encode appConfig)
    logRestyledPullRequest appRestyledPullRequest
  where
    logRestyledPullRequest Nothing = logInfoN "Restyled PR does not exist"
    logRestyledPullRequest (Just pr) =
        logInfoN
            $ "Restyled PR exists ("
            <> showSpec (simplePullRequestSpec pr)
            <> ")"

configEnabled :: MonadApp m => m Bool
configEnabled = asks $ cEnabled . appConfig

commentsEnabled :: MonadApp m => m Bool
commentsEnabled = asks $ cCommentsEnabled . appConfig

data RestyleResult = RestyleResult
    { rrRestylersRan :: [Restyler]
    , rrChangedPaths :: [FilePath]
    }

wasRestyled :: RestyleResult -> Bool
wasRestyled = not . null . rrChangedPaths

restyle :: MonadApp m => m RestyleResult
restyle = do
    config <- asks appConfig
    pullRequest <- asks appPullRequest
    pullRequestPaths <- changedPaths $ pullRequestBaseRef pullRequest

    RestyleResult
        <$> runRestylers (cRestylers config) pullRequestPaths
        <*> changedPaths (pullRequestLocalHeadRef pullRequest)

changedPaths :: MonadApp m => Text -> m [FilePath]
changedPaths branch = do
    output <- lines
        <$> readProcess "git" ["merge-base", unpack branch, "HEAD"] ""
    let ref = maybe branch pack $ listToMaybe output
    lines <$> readProcess "git" ["diff", "--name-only", unpack ref] ""

isAutoPush :: MonadApp m => m Bool
isAutoPush = do
    isAuto <- asks $ cAuto . appConfig
    pullRequest <- asks appPullRequest
    pure $ isAuto && not (pullRequestIsFork pullRequest)

exitWithInfo :: MonadApp m => Text -> m ()
exitWithInfo msg = do
    logInfoN msg
    exitSuccess
