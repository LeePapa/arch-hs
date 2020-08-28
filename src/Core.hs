{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Core where

import qualified Algebra.Graph.Labelled.AdjacencyMap as G
import Control.Monad.Except
import Data.List (intercalate)
import Data.List.Split (splitOn)
import qualified Data.Map as Map
import qualified Data.Set as S
import qualified Distribution.Compat.Lens as L
import Distribution.Compiler
import Distribution.PackageDescription
{- For ghc 8.8.3, the following modules are included in
  GenericPackageDescription.
import Distribution.Types.ConfVar
import Distribution.Types.Flag -}
import Distribution.SPDX
import Distribution.System
import qualified Distribution.Types.BuildInfo.Lens as L
import Distribution.Types.CondTree
import Distribution.Types.Dependency
import qualified Distribution.Types.PackageId as I
import Distribution.Types.PackageName
import Distribution.Types.UnqualComponentName
import Distribution.Types.Version
import Distribution.Types.VersionRange
import Hackage
import Lens.Micro
import Lens.Micro.Mtl
import Local
import PkgBuild
import Types
import Utils

archEnv :: FlagAssignment -> ConfVar -> Either ConfVar Bool
archEnv _ (OS Windows) = Right True
archEnv _ (OS _) = Right False
archEnv _ (Arch X86_64) = Right True
archEnv _ (Arch _) = Right False
archEnv _ (Impl GHC range) = Right $ withinRange (mkVersion [8, 10, 2]) range
archEnv _ (Impl _ _) = Right False
archEnv assignment f@(Flag f') = go f $ lookupFlagAssignment f' assignment
  where
    go _ (Just r) = Right r
    go x Nothing = Left x

evalConditionTree :: (Semigroup k, L.HasBuildInfo k, Monad m) => PackageName -> CondTree ConfVar [Dependency] k -> HsM m BuildInfo
evalConditionTree name cond = do
  flg <- view flags
  let thisFlag = case Map.lookup name flg of
        Just f -> f
        Nothing -> mkFlagAssignment []
  return $ (L.^. L.buildInfo) . snd $ simplifyCondTree (archEnv thisFlag) cond

-----------------------------------------------------------------------------

getDependencies ::
  (Monad m) =>
  S.Set PackageName ->
  Int ->
  PackageName ->
  HsM m (G.AdjacencyMap (S.Set DependencyType) PackageName)
getDependencies resolved n name = do
  cabal <- getLatestCabal name
  (libDeps, libToolsDeps) <- collectLibDeps cabal
  (exeDeps, exeToolsDeps) <- collectExeDeps cabal
  (testDeps, testToolsDeps) <- collectTestDeps cabal
  (benchDeps, benchToolsDeps) <- collectBenchMarkDeps cabal
  let uname :: (UnqualComponentName -> DependencyType) -> ComponentPkgList -> [(DependencyType, PkgList)]
      uname cons list = zip (fmap (cons . fst) list) (fmap snd list)

      flatten :: [(DependencyType, PkgList)] -> [(DependencyType, PackageName)]
      flatten list = mconcat $ fmap (\(t, pkgs) -> zip (repeat t) pkgs) list

      withThisName :: [(DependencyType, PackageName)] -> [(DependencyType, PackageName, PackageName)]
      withThisName = fmap (\(t, pkg) -> (t, name, pkg))

      ignored = filter (\x -> not $ x `elem` ignoreList || x == name || x `elem` resolved)
      filterNot p = filter (not . p)

      currentLib = G.edges $ zip3 (repeat $ S.singleton Lib) (repeat name) $ filterNot (`elem` ignoreList) libDeps
      currentLibDeps = G.edges $ zip3 (repeat $ S.singleton LibBuildTools) (repeat name) $ filterNot (`elem` ignoreList) libToolsDeps

      runnableEdges k l = G.edges $ fmap (\(x, y, z) -> (S.singleton x, y, z)) . withThisName . filterNot (\(_, x) -> x `elem` ignoreList) . flatten . uname k $ l

      currentExe = runnableEdges Exe exeDeps
      currentExeTools = runnableEdges ExeBuildTools exeToolsDeps
      currentTest = runnableEdges Test testDeps
      currentTestTools = runnableEdges TestBuildTools testToolsDeps
      currentBench = runnableEdges Types.Benchmark benchDeps
      currentBenchTools = runnableEdges BenchmarkBuildTools benchToolsDeps

      (<+>) = G.overlay
  -- Only solve lib & exe deps recursively.
  nextLib <- mapM (getDependencies (S.insert name (resolved)) (n + 1)) $ ignored (libDeps)
  nextExe <- mapM (getDependencies (S.insert name (resolved)) (n + 1)) $ ignored . fmap snd . flatten . uname Exe $ exeDeps
  return $
    currentLib
      <+> currentLibDeps
      <+> currentExe
      <+> currentExeTools
      <+> currentTest
      <+> currentTestTools
      <+> currentBench
      <+> currentBenchTools
      <+> (G.overlays nextLib)
      <+> (G.overlays nextExe)

collectLibDeps :: (Monad m) => GenericPackageDescription -> HsM m (PkgList, PkgList)
collectLibDeps cabal = do
  case cabal & condLibrary of
    Just lib -> do
      info <- evalConditionTree (getPkgName cabal) lib
      let libDeps = fmap depPkgName $ targetBuildDepends info
          toolDeps = fmap unExe $ buildToolDepends info
      return (libDeps, toolDeps)
    Nothing -> return ([], [])

collectRunnableDeps ::
  (Monad m, Semigroup k, L.HasBuildInfo k) =>
  (GenericPackageDescription -> [(UnqualComponentName, CondTree ConfVar [Dependency] k)]) ->
  GenericPackageDescription ->
  HsM m (ComponentPkgList, ComponentPkgList)
collectRunnableDeps f cabal = do
  let exes = cabal & f
  info <- zip (fmap fst exes) <$> mapM (evalConditionTree (getPkgName cabal) . snd) exes
  let runnableDeps = fmap (mapSnd $ fmap depPkgName . targetBuildDepends) info
      toolDeps = fmap (mapSnd $ fmap unExe . buildToolDepends) info
  return (runnableDeps, toolDeps)

collectExeDeps :: (Monad m) => GenericPackageDescription -> HsM m (ComponentPkgList, ComponentPkgList)
collectExeDeps = collectRunnableDeps condExecutables

collectTestDeps :: (Monad m) => GenericPackageDescription -> HsM m (ComponentPkgList, ComponentPkgList)
collectTestDeps = collectRunnableDeps condTestSuites

collectBenchMarkDeps :: (Monad m) => GenericPackageDescription -> HsM m (ComponentPkgList, ComponentPkgList)
collectBenchMarkDeps = collectRunnableDeps condBenchmarks

-----------------------------------------------------------------------------

cabalToPkgBuild :: (Monad m) => SolvedPackage -> HsM m PkgBuild
cabalToPkgBuild pkg = do
  let name = pkg ^. pkgName
  cabal <- packageDescription <$> (getLatestCabal name)
  let _hkgName = pkg ^. pkgName & unPackageName
      _pkgName = toLower' _hkgName
      _pkgVer = intercalate "." . fmap show . versionNumbers . I.pkgVersion . package $ cabal
      _pkgDesc = synopsis cabal
      (License (ELicense (ELicenseId cabalLicense) _)) = license cabal --  TODO unexhausted
      _license = show . mapLicense $ cabalLicense
      _depends = pkg ^. pkgDeps ^.. each . filtered (\x -> notMyself x && notInGHCLib x && (selectDepType isLib x || selectDepType isExe x)) & depsToString
      _makeDepends = pkg ^. pkgDeps ^.. each . filtered (\x -> notMyself x && notInGHCLib x && (selectDepType isLibBuildTools x || selectDepType isTest x || selectDepType isTestBuildTools x)) & depsToString
      depsToString deps = deps <&> (wrap . fixName . unPackageName . _depName) & intercalate " "
      wrap s = '\'' : s ++ "\'"
      fromJust (Just x) = return x
      fromJust _ = throwError $ UrlError name
      head' (x : _) = return x
      head' [] = throwError $ UrlError name
      notInGHCLib x = not ((x ^. depName) `elem` ghcLibList)
      notMyself x = x ^. depName /= name
      selectDepType f x = any f (x ^. depType)
      fixName s = case splitOn "-" s of
        ("haskell" : _) -> toLower' s
        _ -> "haskell-" ++ toLower' s
  _url <- case homepage cabal of
    "" -> fromJust . repoLocation <=< head' $ sourceRepos cabal
    x -> return x
  return PkgBuild {..}