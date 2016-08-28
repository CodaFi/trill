//
//  ClangImporter.swift
//  Trill
//

import Foundation

extension CXErrorCode: Error, CustomStringConvertible {
  public var description: String {
    switch self {
    case CXError_Success:
      return "CXErrorCode.success"
    case CXError_Crashed:
      return "CXErrorCode.crashed"
    case CXError_Failure:
      return "CXErrorCode.failure"
    case CXError_ASTReadError:
      return "CXErrorCode.astReadError"
    case CXError_InvalidArguments:
      return "CXErrorCode.invalidArguments"
    default:
      fatalError("unknown CXErrorCode: \(self.rawValue)")
    }
  }
}

enum ImportError: Error {
  case pastIntMax
}

extension CXCursor {
  var isInvalid: Bool {
    switch self.kind {
    case CXCursor_InvalidCode: return true
    case CXCursor_InvalidFile: return true
    case CXCursor_LastInvalid: return true
    case CXCursor_FirstInvalid: return true
    case CXCursor_NotImplemented: return true
    case CXCursor_NoDeclFound: return true
    default: return false
    }
  }
  var isValid: Bool { return !self.isInvalid }
}

extension Collection where Iterator.Element == String, IndexDistance == Int {
  func withCArrayOfCStrings<Result>(_ f: (UnsafeMutablePointer<UnsafePointer<Int8>?>) throws -> Result) rethrows -> Result {
    let ptr = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: self.count)
    defer  { freelist(ptr, count: self.count) }
    for (idx, str) in enumerated() {
      str.withCString { cStr in
        ptr[idx] = strdup(cStr)
      }
    }
    return try f(unsafeBitCast(ptr, to: UnsafeMutablePointer<UnsafePointer<Int8>?>.self))
  }
}

func freelist<T>(_ ptr: UnsafeMutablePointer<UnsafeMutablePointer<T>?>, count: Int) {
  for i in 0..<count {
    free(ptr[i])
  }
  free(ptr)
}

extension CXString {
  func asSwift() -> String {
    defer { clang_disposeString(self) }
    let str = String(cString: clang_getCString(self))
    let components = str.components(separatedBy: " ")
    return components.last ?? str
  }
}

class ClangImporter: Pass {
  
  static let headerFiles = [
    "stdlib.h",
    "stdio.h",
    "stdint.h",
    "stddef.h",
    "math.h",
    "string.h",
    "_types.h",
    "pthread.h",
  ]
  
  #if os(macOS)
  // TODO: PLEASE stop using these absolute Xcode paths.
  static let paths = headerFiles.map { "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/" + $0 } + ["/usr/local/include/trill/trill.h"]
  #else
  static let paths = headerFiles.map { "/usr/local/include/" + $0 } + ["/usr/local/include/trill/trill.h"]
  #endif
  
  let context: ASTContext
  
  var importedTypes = [Identifier: TypeDecl]()
  var importedFunctions = [Identifier: FuncDecl]()
  
  required init(context: ASTContext) {
    self.context = context
  }
  
  var title: String {
    return "Clang Importer"
  }
  
  func translationUnit(for path: String) throws -> CXTranslationUnit {
    let index = clang_createIndex(0, 0)
    var args = [
      "-c",
      "-I/usr/include",
      "-I/usr/local/include",
      "-I/usr/local/llvm/include",
      ]
    #if os(macOS)
      args.append("-I/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/")
    #endif
    defer {
      clang_disposeIndex(index)
    }
    
    let flags = [
      CXTranslationUnit_SkipFunctionBodies,
      CXTranslationUnit_DetailedPreprocessingRecord
    ].reduce(0 as UInt32) { $0 | $1.rawValue }
    
    return try args.withCArrayOfCStrings { ptr in
      var tu: CXTranslationUnit? = nil
      let err = clang_parseTranslationUnit2(index, path,
                                            ptr, 1, nil,
                                            0, flags, &tu)
      guard err == CXError_Success else {
        throw err
      }
      guard let _tu = tu else {
        throw CXError_Failure
      }
      return _tu
    }
  }
  
  func synthesize(name: String, args: [DataType],
                  return: DataType,
                  hasVarArgs: Bool,
                  attributes: [DeclAttribute]) -> FuncDecl {
    return FuncDecl(name: Identifier(name: name),
                        returnType: `return`.ref(),
                        args: args.map { FuncArgumentAssignDecl(name: "", type: $0.ref()) },
                        attributes: attributes,
                        hasVarArgs: hasVarArgs)
  }
  
  @discardableResult
  func importTypeDef(_ cursor: CXCursor) -> TypeAliasExpr? {
    let name = clang_getCursorSpelling(cursor).asSwift()
    let type = clang_getTypedefDeclUnderlyingType(cursor)
    let decl = clang_getTypeDeclaration(type)
    var trillType: DataType?
    if decl.kind == CXCursor_StructDecl {
      if let expr = importStruct(decl) {
        trillType = expr.type
      } else {
        return nil
      }
    } else {
      trillType = convertToTrillType(type)
    }
    guard let t = trillType, name != "\(t)" else {
      return nil
    }
    let alias = TypeAliasExpr(name: Identifier(name: name),
                              bound: t.ref())
    self.context.add(alias)
    return alias
  }
  
  @discardableResult
  func importStruct(_ cursor: CXCursor) -> TypeDecl? {
    let type = clang_getCursorType(cursor)
    let typeName = clang_getTypeSpelling(type).asSwift()
    
    let name = Identifier(name: typeName)
    
    if let e = importedTypes[name] { return e }
    
    var values = [VarAssignDecl]()
    
    clang_visitChildrenWithBlock(cursor) { child, parent in
      let fieldId = Identifier(name: clang_getCursorSpelling(child).asSwift(),
                               range: nil)
      let fieldTy = clang_getCursorType(child)
      guard let trillTy = self.convertToTrillType(fieldTy) else {
        return CXChildVisit_Break
      }
      let expr = VarAssignDecl(name: fieldId,
                               typeRef: trillTy.ref(),
                               attributes: [.foreign],
                               mutable: true)
      values.append(expr)
      return CXChildVisit_Continue
    }
    
    let expr = TypeDecl(name: name, fields: values, attributes: [.foreign])
    importedTypes[name] = expr
    self.context.add(expr)
    return expr
  }
  
  func importFunction(_ cursor: CXCursor)  {
    let name = clang_getCursorSpelling(cursor).asSwift()
    let existing = context.functions(named: Identifier(name: name))
    if !existing.isEmpty { return }
    let numArgs = clang_Cursor_getNumArguments(cursor)
    guard numArgs != -1 else { return }
    var attributes = [DeclAttribute.foreign]
    if clang_isNoReturn(cursor) != 0 {
      attributes.append(.noreturn)
    }
    let hasVarArgs = clang_Cursor_isVariadic(cursor) != 0
    let funcType = clang_getCursorType(cursor)
    let returnTy = clang_getResultType(funcType)
    
    guard let trillRetTy = convertToTrillType(returnTy) else { return }
    
    var args = [DataType]()
    for i in 0..<numArgs {
      let type = clang_getArgType(funcType, UInt32(i))
      guard let trillType = convertToTrillType(type) else { return }
      args.append(trillType)
    }
    
    let decl = synthesize(name: name,
                          args: args,
                          return: trillRetTy,
                          hasVarArgs: hasVarArgs,
                          attributes: attributes)
    importedFunctions[decl.name] = decl
    self.context.add(decl)
  }
  
  func importEnum(_ cursor: CXCursor) {
    clang_visitChildrenWithBlock(cursor) { child, parent in
      let name = Identifier(name: clang_getCursorSpelling(child).asSwift())
      let varExpr = VarAssignDecl(name: name,
                                  typeRef: DataType.int32.ref(),
                                  mutable: false)
      self.context.add(varExpr)
      return CXChildVisit_Continue
    }
  }
  
  func importMacro(_ cursor: CXCursor, in tu: CXTranslationUnit) {
    let range = clang_getCursorExtent(cursor)
    
    var tokenCount: UInt32 = 0
    var _tokens: UnsafeMutablePointer<CXToken>?
    clang_tokenize(tu, range, &_tokens, &tokenCount)
    
    guard let tokens = _tokens, tokenCount > 2 else { return }
    
    defer {
      clang_disposeTokens(tu, tokens, tokenCount)
    }
    
    let cursors = UnsafeMutablePointer<CXCursor>.allocate(capacity: Int(tokenCount))
    defer {
      free(cursors)
    }
    clang_annotateTokens(tu, tokens, tokenCount, cursors)
    
    let name = clang_getTokenSpelling(tu, tokens[0]).asSwift()
    guard context.global(named: name) == nil else { return }
    guard clang_getTokenKind(tokens[1]) == CXToken_Literal else { return }
    guard let assign = parse(tu: tu, token: tokens[1], name: name) else { return }
    context.add(assign)
  }
  
  // FIXME: Actually use Clang's lexer instead of re-implementing parts of
  //        it, poorly.
  func simpleParseIntegerLiteralToken(_ token: String) throws -> TokenKind? {
    let lexer = Lexer(input: token)
    let numStr = lexer.collectWhile { $0.isNumeric }
    guard let num = IntMax(numStr) else { throw ImportError.pastIntMax }
    let suffix = lexer.collectWhile { $0.isIdentifier }
    for char in suffix.lowercased().characters {
      if char != "u" && char != "l" { return nil }
    }
    return .number(value: num, raw: numStr)
  }
  
  func simpleParseCToken(_ token: String) throws -> TokenKind? {
    let toks = try Lexer(input: token).lex()
    guard let first = toks.first?.kind else { return nil }
    if case .identifier(let name) = first {
      return try simpleParseIntegerLiteralToken(name) ?? first
    }
    return first
  }
  
  func parse(tu: CXTranslationUnit, token: CXToken, name: String) -> VarAssignDecl? {
    do {
      let tok = clang_getTokenSpelling(tu, token).asSwift()
      guard let token = try simpleParseCToken(tok) else { return nil }
      var expr: Expr! = nil
      switch token {
      case .char(let value):
        expr = CharExpr(value: value)
      case .stringLiteral(let value):
        expr = StringExpr(value: value)
      case .number(let value, let raw):
        expr = NumExpr(value: value, raw: raw)
      case .identifier(let name):
        expr = VarExpr(name: Identifier(name: name))
      default:
        return nil
      }
      return VarAssignDecl(name: Identifier(name: name),
                           typeRef: expr.type?.ref(),
                           rhs: expr,
                           mutable: false)
    } catch { return nil }
  }
  
  func makeAlias(name: String, type: DataType) -> TypeAliasExpr {
    return TypeAliasExpr(name: Identifier(name: name),
                         bound: type.ref())
  }
  
  func run(in context: ASTContext) {
    self.context.add(makeAlias(name: "uint16_t", type: .int16))
    self.context.add(makeAlias(name: "__builtin_va_list", type: .pointer(type: .int8)))
    self.context.add(makeAlias(name: "__darwin_pthread_handler_rec", type: .pointer(type: .int8)))
    self.context.add(synthesize(name: "trill_fatalError",
                                args: [.pointer(type: .int8)],
                                return: .void,
                                hasVarArgs: false,
                                attributes: [.foreign, .noreturn]))
    for path in ClangImporter.paths {
      do {
        let tu = try translationUnit(for: path)
        let cursor = clang_getTranslationUnitCursor(tu)
        clang_visitChildrenWithBlock(cursor) { child, parent in
          let kind = clang_getCursorKind(child)
          switch kind {
          case CXCursor_TypedefDecl:
            self.importTypeDef(child)
          case CXCursor_EnumDecl:
            self.importEnum(child)
          case CXCursor_StructDecl:
            self.importStruct(child)
          case CXCursor_FunctionDecl:
            self.importFunction(child)
          case CXCursor_MacroDefinition:
            self.importMacro(child, in: tu)
          default:
            break
          }
          return CXChildVisit_Continue
        }
        // clang_disposeTranslationUnit(tu)
      } catch {
        print("Error loading \(path): \(error)")
      }
    }
  }
  
  func convertToTrillType(_ type: CXType) -> DataType? {
    switch type.kind {
    case CXType_Void: return .void
    case CXType_Int: return .int32
    case CXType_Bool: return .bool
    case CXType_Enum: return .int32
    case CXType_Float: return .float
    case CXType_Double: return .double
    case CXType_LongDouble: return .float80
    case CXType_Long: return .int64
    case CXType_UInt: return .int32
    case CXType_LongLong: return .int64
    case CXType_ULong: return .int64
    case CXType_ULongLong: return .int64
    case CXType_Short: return .int16
    case CXType_UShort: return .int16
    case CXType_SChar: return .int8
    case CXType_Char_S: return .int8
    case CXType_Char16: return .int16
    case CXType_Char32: return .int32
    case CXType_UChar: return .int8
    case CXType_WChar: return .int16
    case CXType_ObjCSel: return .pointer(type: .int8)
    case CXType_ObjCId: return .pointer(type: .int8)
    case CXType_NullPtr: return .pointer(type: .int8)
    case CXType_Unexposed: return .pointer(type: .int8)
    case CXType_ConstantArray:
      let underlying = clang_getArrayElementType(type)
      guard let trillTy = convertToTrillType(underlying) else { return nil }
      return .pointer(type: trillTy)
    case CXType_Pointer:
      let pointee = clang_getPointeeType(type)
      // Check to see if the pointee is a function type:
      if clang_getResultType(pointee).kind != CXType_Invalid {
        // function pointer type.
        guard let t = convertFunctionType(pointee) else { return nil }
        return t
      }
      let trillPointee: DataType?
      if pointee.kind == CXType_Void {
        trillPointee = .int8
      } else {
        trillPointee = convertToTrillType(pointee)
      }
      guard let p = trillPointee else {
        return nil
      }
      return .pointer(type: p)
    case CXType_FunctionProto:
      return convertFunctionType(type)
    case CXType_FunctionNoProto:
      let ret = clang_getResultType(type)
      guard let trillRet = convertToTrillType(ret) else { return nil }
      return .function(args: [], returnType: trillRet)
    case CXType_Typedef:
      let typeName = clang_getTypeSpelling(type).asSwift()
      return .custom(name: typeName)
    case CXType_Record:
      let name = clang_getTypeSpelling(type).asSwift()
      return .custom(name: name)
    case CXType_ConstantArray:
      let element = clang_getArrayElementType(type)
      let size = clang_getNumArgTypes(type)
      guard let trillElType = convertToTrillType(element) else { return nil }
      return .tuple(fields: [DataType](repeating: trillElType, count: Int(size)))
    case CXType_Invalid:
      return nil
    default:
      return nil
    }
  }
  
  func convertFunctionType(_ type: CXType) -> DataType? {
    let ret = clang_getResultType(type)
    let trillRet = convertToTrillType(ret) ?? .void
    let numArgs = clang_getNumArgTypes(type)
    
    guard numArgs != -1 else { return nil }
    
    var args = [DataType]()
    for i in 0..<UInt32(numArgs) {
      let type = clang_getArgType(type, UInt32(i))
      guard let trillArgTy = convertToTrillType(type) else { return nil }
      args.append(trillArgTy)
    }
    return .function(args: args, returnType: trillRet)
  }
}