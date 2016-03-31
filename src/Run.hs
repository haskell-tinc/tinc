{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
module Run where

import           Prelude ()
import           Prelude.Compat

import           Control.Exception
import           Control.Monad.Compat
import           Development.GitRev
import           System.Environment
import           System.FileLock
import           System.FilePath
import           System.Process

import           Tinc.Install
import           Tinc.Facts
import           Tinc.Types
import           Tinc.Nix
import           Tinc.RecentCheck

unsetEnvVars :: IO ()
unsetEnvVars = do
  unsetEnv "CABAL_SANDBOX_CONFIG"
  unsetEnv "CABAL_SANDBOX_PACKAGE_PATH"
  unsetEnv "GHC_PACKAGE_PATH"

tinc :: [String] -> IO ()
tinc args = do
  unsetEnvVars
  facts@Facts{..} <- getExecutablePath >>= discoverFacts
  case args of
    [] -> do
      recent <- tincEnvCreationTime facts >>= isRecent
      unless recent $ do
        withCacheLock factsCache $ do
          installDependencies False facts
    ["--dry-run"] -> withCacheLock factsCache $
      installDependencies True facts
    ["--version"] -> putStrLn $(gitHash)
    name : rest | Just plugin <- lookup name factsPlugins -> callPlugin facts plugin rest
    _ -> throwIO (ErrorCall $ "unrecognized arguments: " ++ show args)

callPlugin :: Facts -> String -> [String] -> IO ()
callPlugin Facts{..} name args = do
  pid <- if factsUseNix
    then uncurry spawnProcess $ nixShell name args
    else spawnProcess name args
  waitForProcess pid >>= throwIO

withCacheLock :: Path CacheDir -> IO a -> IO a
withCacheLock cache action = do
  putStrLn $ "Acquiring " ++ lock
  withFileLock lock Exclusive $ \ _ -> action
  where
    lock = path cache </> "tinc.lock"
