module Tinc.Facts where

import           Data.List
import           Control.Monad
import           Data.Maybe
import           System.Directory
import           System.Environment
import           System.FilePath
import           Data.Function

import           Tinc.GhcInfo
import           Tinc.AddSource
import           Tinc.Types

data NixCache
type Plugins = [Plugin]
type Plugin = (String, FilePath)

data Facts = Facts {
  factsCache :: Path CacheDir
, factsGitCache :: Path GitCache
, factsAddSourceCache :: Path AddSourceCache
, factsNixCache :: Path NixCache
, factsUseNix :: Bool
, factsPlugins :: Plugins
, factsGhcInfo :: GhcInfo
} deriving (Eq, Show)

tincEnvVar :: String
tincEnvVar = "TINC_USE_NIX"

useNix :: FilePath -> IO Bool
useNix executablePath = do
  maybe (isInNixStore executablePath) (`notElem` ["no", "0"]) <$> lookupEnv tincEnvVar

isInNixStore :: FilePath -> Bool
isInNixStore = ("/nix/" `isPrefixOf`)

discoverFacts :: FilePath -> IO Facts
discoverFacts executablePath = getGhcInfo >>= discoverFacts_impl executablePath

discoverFacts_impl :: FilePath -> GhcInfo -> IO Facts
discoverFacts_impl executablePath ghcInfo = do
  home <- getHomeDirectory
  useNix_ <- useNix executablePath
  let pluginsDir :: FilePath
      pluginsDir = home </> ".tinc" </> "plugins"

      cacheDir :: Path CacheDir
      cacheDir = Path (home </> ".tinc" </> "cache" </> ghcFlavor ghcInfo)

      gitCache :: Path GitCache
      gitCache = Path (home </> ".tinc" </> "cache" </> "git")

      addSourceCache :: Path AddSourceCache
      addSourceCache = Path (home </> ".tinc" </> "cache" </> "add-source")

      nixCache :: Path NixCache
      nixCache = Path (home </> ".tinc" </> "cache" </> "nix")

  createDirectoryIfMissing True (path cacheDir)
  createDirectoryIfMissing True (path nixCache)
  createDirectoryIfMissing True pluginsDir
  plugins <- listAllPlugins pluginsDir
  if useNix_
     then setEnv tincEnvVar "yes"
     else setEnv tincEnvVar "no"
  return Facts {
    factsCache = cacheDir
  , factsGitCache = gitCache
  , factsAddSourceCache = addSourceCache
  , factsNixCache = nixCache
  , factsUseNix = useNix_
  , factsPlugins = plugins
  , factsGhcInfo = ghcInfo
  }

listAllPlugins :: FilePath -> IO Plugins
listAllPlugins pluginsDir = do
  plugins <- listPlugins pluginsDir
  pathPlugins <- getSearchPath >>= listPathPlugins
  return (pathPlugins ++ plugins)

listPlugins :: FilePath -> IO Plugins
listPlugins pluginsDir = do
  exists <- doesDirectoryExist pluginsDir
  if exists
    then do
      files <- mapMaybe (stripPrefix "tinc-") <$> getDirectoryContents pluginsDir
      let f name = (name, pluginsDir </> "tinc-" ++ name)
      filterM isExecutable (map f files)
    else return []

isExecutable :: Plugin -> IO Bool
isExecutable = fmap executable . getPermissions . snd

listPathPlugins :: [FilePath] -> IO Plugins
listPathPlugins = fmap (nubBy ((==) `on` fst) . concat) . mapM listPlugins
