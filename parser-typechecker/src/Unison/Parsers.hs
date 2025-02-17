module Unison.Parsers where

import Data.Text qualified as Text
import Unison.Builtin qualified as Builtin
import Unison.NamesWithHistory qualified as Names
import Unison.Parser.Ann (Ann)
import Unison.Prelude
import Unison.PrintError
  ( defaultWidth,
    prettyParseError,
  )
import Unison.Symbol (Symbol)
import Unison.Syntax.FileParser qualified as FileParser
import Unison.Syntax.Parser qualified as Parser
import Unison.Syntax.TermParser qualified as TermParser
import Unison.Syntax.TypeParser qualified as TypeParser
import Unison.Term (Term)
import Unison.Type (Type)
import Unison.UnisonFile (UnisonFile)
import Unison.Util.Pretty qualified as Pr
import Unison.Var (Var)

unsafeGetRightFrom :: (Var v, Show v) => String -> Either (Parser.Err v) a -> a
unsafeGetRightFrom src =
  either (error . Pr.toANSI defaultWidth . prettyParseError src) id

parse ::
  (Var v) =>
  Parser.P v a ->
  String ->
  Parser.ParsingEnv ->
  Either (Parser.Err v) a
parse p = Parser.run (Parser.root p)

parseTerm ::
  (Var v) =>
  String ->
  Parser.ParsingEnv ->
  Either (Parser.Err v) (Term v Ann)
parseTerm = parse TermParser.term

parseType ::
  (Var v) =>
  String ->
  Parser.ParsingEnv ->
  Either (Parser.Err v) (Type v Ann)
parseType = Parser.run (Parser.root TypeParser.valueType)

parseFile ::
  (Var v) =>
  FilePath ->
  String ->
  Parser.ParsingEnv ->
  Either (Parser.Err v) (UnisonFile v Ann)
parseFile filename s = Parser.run' (Parser.rootFile FileParser.file) s filename

readAndParseFile ::
  (Var v) =>
  Parser.ParsingEnv ->
  FilePath ->
  IO (Either (Parser.Err v) (UnisonFile v Ann))
readAndParseFile penv fileName = do
  txt <- readUtf8 fileName
  let src = Text.unpack txt
  pure $ parseFile fileName src penv

unsafeParseTerm :: (Var v) => String -> Parser.ParsingEnv -> Term v Ann
unsafeParseTerm s = fmap (unsafeGetRightFrom s) . parseTerm $ s

unsafeReadAndParseFile ::
  Parser.ParsingEnv -> FilePath -> IO (UnisonFile Symbol Ann)
unsafeReadAndParseFile penv fileName = do
  txt <- readUtf8 fileName
  let str = Text.unpack txt
  pure . unsafeGetRightFrom str $ parseFile fileName str penv

unsafeParseFileBuiltinsOnly ::
  FilePath -> IO (UnisonFile Symbol Ann)
unsafeParseFileBuiltinsOnly =
  unsafeReadAndParseFile $
    Parser.ParsingEnv
      mempty
      (Names.NamesWithHistory Builtin.names0 mempty)

unsafeParseFile ::
  String -> Parser.ParsingEnv -> UnisonFile Symbol Ann
unsafeParseFile s pEnv = unsafeGetRightFrom s $ parseFile "" s pEnv
