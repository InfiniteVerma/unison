{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Unison.Server.Errors where

import Data.ByteString.Lazy.Char8 qualified as BSC
import Data.Set qualified as Set
import Data.Text.Lazy qualified as Text
import Data.Text.Lazy.Encoding qualified as Text
import Servant (ServerError (..), err400, err404, err409, err500)
import U.Codebase.HashTags (BranchHash, CausalHash)
import Unison.Codebase.Path qualified as Path
import Unison.Codebase.ShortCausalHash qualified as SCH
import Unison.HashQualified qualified as HQ
import Unison.Name (Name)
import Unison.Prelude
import Unison.Reference qualified as Reference
import Unison.Server.Backend qualified as Backend
import Unison.Server.Types
  ( HashQualifiedName,
    munge,
    mungeShow,
    mungeString,
  )
import Unison.ShortHash qualified as SH
import Unison.Syntax.HashQualified qualified as HQ (toString)

badHQN :: HashQualifiedName -> ServerError
badHQN hqn =
  err400
    { errBody =
        Text.encodeUtf8 (Text.fromStrict hqn)
          <> " is not a well-formed name, hash, or hash-qualified name. "
          <> "I expected something like `foo`, `#abc123`, or `foo#abc123`."
    }

backendError :: Backend.BackendError -> ServerError
backendError = \case
  Backend.NoSuchNamespace n ->
    noSuchNamespace . Path.toText $ Path.unabsolute n
  Backend.BadNamespace err namespace -> badNamespace err namespace
  Backend.NoBranchForHash h ->
    noSuchNamespace . Text.toStrict . Text.pack $ show h
  Backend.CouldntLoadBranch h ->
    couldntLoadBranch h
  Backend.CouldntExpandBranchHash h ->
    noSuchNamespace . Text.toStrict . Text.pack $ show h
  Backend.AmbiguousBranchHash sch hashes ->
    ambiguousNamespace (SCH.toText sch) (Set.map SCH.toText hashes)
  Backend.MissingSignatureForTerm r -> missingSigForTerm $ Reference.toText r
  Backend.NoSuchDefinition hqName -> noSuchDefinition hqName
  Backend.AmbiguousHashForDefinition shorthash -> ambiguousHashForDefinition shorthash
  Backend.ExpectedNameLookup branchHash -> expectedNameLookup branchHash
  Backend.DisjointProjectAndPerspective perspective projectRoot -> disjointProjectAndPerspective perspective projectRoot

badNamespace :: String -> String -> ServerError
badNamespace err namespace =
  err400
    { errBody =
        "Malformed namespace: "
          <> mungeString namespace
          <> ". "
          <> mungeString err
    }

noSuchNamespace :: HashQualifiedName -> ServerError
noSuchNamespace namespace =
  err404 {errBody = "The namespace " <> munge namespace <> " does not exist."}

couldntLoadBranch :: CausalHash -> ServerError
couldntLoadBranch h =
  err404
    { errBody =
        "The namespace "
          <> munge (Text.toStrict . Text.pack $ show h)
          <> " exists but couldn't be loaded."
    }

ambiguousNamespace :: HashQualifiedName -> Set HashQualifiedName -> ServerError
ambiguousNamespace name namespaces =
  err409
    { errBody =
        "Ambiguous namespace reference: "
          <> munge name
          <> ". It could refer to any of "
          <> mungeShow (Set.toList namespaces)
    }

missingSigForTerm :: HashQualifiedName -> ServerError
missingSigForTerm r =
  err500
    { errBody =
        "The type signature for reference "
          <> munge r
          <> " is missing! "
          <> "This means something might be wrong with the codebase, "
          <> "or the term was deleted just now. "
          <> "Try making the request again."
    }

noSuchDefinition :: HQ.HashQualified Name -> ServerError
noSuchDefinition hqName =
  err404
    { errBody =
        "Couldn't find a definition for " <> BSC.pack (HQ.toString hqName)
    }

ambiguousHashForDefinition :: SH.ShortHash -> ServerError
ambiguousHashForDefinition shorthash =
  err400
    { errBody =
        "The hash prefix " <> BSC.pack (SH.toString shorthash) <> " is ambiguous"
    }

expectedNameLookup :: BranchHash -> ServerError
expectedNameLookup branchHash =
  err500
    { errBody =
        "Name lookup index required for branch hash: " <> BSC.pack (show branchHash)
    }

disjointProjectAndPerspective :: Path.Path -> Path.Path -> ServerError
disjointProjectAndPerspective perspective projectRoot =
  err500
    { errBody =
        "The project root "
          <> munge (Path.toText projectRoot)
          <> " is disjoint with the perspective "
          <> munge (Path.toText perspective)
          <> ". This is a bug, please report it."
    }
