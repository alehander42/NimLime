#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Nimsuggest is a tool that helps to give editors IDE like capabilities.

import strutils, os, parseopt, parseutils, sequtils, net, rdstdin, sexp
# Do NOT import suggest. It will lead to wierd bugs with
# suggestionResultHook, because suggest.nim is included by sigmatch.
# So we import that one instead.
import compiler/options, compiler/commands, compiler/modules, compiler/sem,
  compiler/passes, compiler/passaux, compiler/msgs, compiler/nimconf,
  compiler/extccomp, compiler/condsyms, compiler/lists,
  compiler/sigmatch, compiler/ast

when defined(windows):
  import winlean
else:
  import posix

const Usage = """
Nimsuggest - Tool to give every editor IDE like capabilities for Nim
Usage:
  nimsuggest [options] projectfile.nim

Options:
  --port:PORT                port, by default 6000
  --address:HOST             binds to that address, by default ""
  --stdin                    read commands from stdin and write results to
                             stdout instead of using sockets
  --epc                      use emacs epc mode
  --debug                    enable debug output
  --v2                       use version 2 of the protocol; more features and
                             much faster

The server then listens to the connection and takes line-based commands.

In addition, all command line options of Nim that do not affect code generation
are supported.
"""
type
  Mode = enum mstdin, mtcp, mepc

var
  gPort = 6000.Port
  gAddress = ""
  gMode: Mode

const
  seps = {':', ';', ' ', '\t'}
  Help = "usage: sug|con|def|use|dus|chk|highlight|outline file.nim[;dirtyfile.nim]:line:col\n" &
         "type 'quit' to quit\n" &
         "type 'debug' to toggle debug mode on/off\n" &
         "type 'terse' to toggle terse mode on/off"

type
  EUnexpectedCommand = object of Exception

proc parseQuoted(cmd: string; outp: var string; start: int): int =
  var i = start
  i += skipWhitespace(cmd, i)
  if cmd[i] == '"':
    i += parseUntil(cmd, outp, '"', i+1)+2
  else:
    i += parseUntil(cmd, outp, seps, i)
  result = i

proc sexp(s: IdeCmd): SexpNode = sexp($s)

proc sexp(s: TSymKind): SexpNode = sexp($s)

proc sexp(s: Suggest): SexpNode =
  # If you change the oder here, make sure to change it over in
  # nim-mode.el too.
  result = convertSexp([
    s.section,
    s.symkind,
    s.qualifiedPath.map(newSString),
    s.filePath,
    s.forth,
    s.line,
    s.column,
    s.doc
  ])

proc sexp(s: seq[Suggest]): SexpNode =
  result = newSList()
  for sug in s:
    result.add(sexp(sug))

proc listEPC(): SexpNode =
  let
    argspecs = sexp("file line column dirtyfile".split(" ").map(newSSymbol))
    docstring = sexp("line starts at 1, column at 0, dirtyfile is optional")
  result = newSList()
  for command in ["sug", "con", "def", "use", "dus"]:
    let
      cmd = sexp(command)
      methodDesc = newSList()
    methodDesc.add(cmd)
    methodDesc.add(argspecs)
    methodDesc.add(docstring)
    result.add(methodDesc)

proc findNode(n: PNode): PSym =
  #echo "checking node ", n.info
  if n.kind == nkSym:
    if isTracked(n.info, n.sym.name.s.len): return n.sym
  else:
    for i in 0 ..< safeLen(n):
      let res = n.sons[i].findNode
      if res != nil: return res

proc symFromInfo(gTrackPos: TLineInfo): PSym =
  let m = getModule(gTrackPos.fileIndex)
  #echo m.isNil, " I knew it ", gTrackPos.fileIndex
  if m != nil and m.ast != nil:
    result = m.ast.findNode

proc execute(cmd: IdeCmd, file, dirtyfile: string, line, col: int) =
  gIdeCmd = cmd
  if cmd == ideUse and suggestVersion != 2:
    modules.resetAllModules()
  var isKnownFile = true
  let dirtyIdx = file.fileInfoIdx(isKnownFile)

  if dirtyfile.len != 0: msgs.setDirtyFile(dirtyIdx, dirtyfile)
  else: msgs.setDirtyFile(dirtyIdx, nil)

  gTrackPos = newLineInfo(dirtyIdx, line, col)
  gErrorCounter = 0
  if suggestVersion < 2:
    usageSym = nil
  if not isKnownFile:
    compileProject()
  if suggestVersion == 2 and gIdeCmd in {ideDef, ideUse, ideDus} and
      dirtyfile.len == 0:
    discard "no need to recompile anything"
  else:
    resetModule dirtyIdx
    if dirtyIdx != gProjectMainIdx:
      resetModule gProjectMainIdx
    compileProject(dirtyIdx)
  if gIdeCmd in {ideUse, ideDus}:
    let u = if suggestVersion >= 2: symFromInfo(gTrackPos) else: usageSym
    if u != nil:
      listUsages(u)
    else:
      localError(gTrackPos, "found no symbol at this position " & $gTrackPos)

proc executeEPC(cmd: IdeCmd, args: SexpNode) =
  let
    file = args[0].getStr
    line = args[1].getNum
    column = args[2].getNum
  var dirtyfile = ""
  if len(args) > 3:
    dirtyfile = args[3].getStr(nil)
  execute(cmd, file, dirtyfile, int(line), int(column))

proc returnEPC(socket: var Socket, uid: BiggestInt, s: SexpNode,
               return_symbol = "return") =
  let response = $convertSexp([newSSymbol(return_symbol), uid, s])
  socket.send(toHex(len(response), 6))
  socket.send(response)

proc connectToNextFreePort(server: Socket, host: string, start = 30000): int =
  result = start
  while true:
    try:
      server.bindaddr(Port(result), host)
      return
    except OsError:
      when defined(windows):
        let checkFor = WSAEADDRINUSE.OSErrorCode
      else:
        let checkFor = EADDRINUSE.OSErrorCode
      if osLastError() != checkFor:
        raise getCurrentException()
      else:
        result += 1

proc parseCmdLine(cmd: string) =
  template toggle(sw) =
    if sw in gGlobalOptions:
      excl(gGlobalOptions, sw)
    else:
      incl(gGlobalOptions, sw)
    return

  template err() =
    echo Help
    return

  var opc = ""
  var i = parseIdent(cmd, opc, 0)
  case opc.normalize
  of "sug": gIdeCmd = ideSug
  of "con": gIdeCmd = ideCon
  of "def": gIdeCmd = ideDef
  of "use": gIdeCmd = ideUse
  of "dus": gIdeCmd = ideDus
  of "chk":
    gIdeCmd = ideChk
    incl(gGlobalOptions, optIdeDebug)
  of "highlight": gIdeCmd = ideHighlight
  of "outline": gIdeCmd = ideOutline
  of "quit": quit()
  of "debug": toggle optIdeDebug
  of "terse": toggle optIdeTerse
  else: err()
  var dirtyfile = ""
  var orig = ""
  i = parseQuoted(cmd, orig, i)
  if cmd[i] == ';':
    i = parseQuoted(cmd, dirtyfile, i+1)
  i += skipWhile(cmd, seps, i)
  var line = -1
  var col = 0
  i += parseInt(cmd, line, i)
  i += skipWhile(cmd, seps, i)
  i += parseInt(cmd, col, i)

  execute(gIdeCmd, orig, dirtyfile, line, col-1)

proc serveStdin() =
  echo Help
  var line = ""
  while readLineFromStdin("> ", line):
    parseCmdLine line
    echo ""
    flushFile(stdout)

proc serveTcp() =
  var server = newSocket()
  server.bindAddr(gPort, gAddress)
  var inp = "".TaintedString
  server.listen()

  while true:
    var stdoutSocket = newSocket()
    msgs.writelnHook = proc (line: string) =
      stdoutSocket.send(line & "\c\L")

    accept(server, stdoutSocket)

    stdoutSocket.readLine(inp)
    parseCmdLine inp.string

    stdoutSocket.send("\c\L")
    stdoutSocket.close()

proc serveEpc(server: Socket) =
  var inp = "".TaintedString
  var client = newSocket()
  # Wait for connection
  accept(server, client)
  while true:
    var sizeHex = ""
    if client.recv(sizeHex, 6) != 6:
      raise newException(ValueError, "didn't get all the hexbytes")
    var size = 0
    if parseHex(sizeHex, size) == 0:
      raise newException(ValueError, "invalid size hex: " & $sizeHex)
    var messageBuffer = ""
    if client.recv(messageBuffer, size) != size:
      raise newException(ValueError, "didn't get all the bytes")
    let
      message = parseSexp($messageBuffer)
      messageType = message[0].getSymbol
    case messageType:
    of "call":
      var results: seq[Suggest] = @[]
      suggestionResultHook = proc (s: Suggest) =
        results.add(s)

      let
        uid = message[1].getNum
        cmd = parseIdeCmd(message[2].getSymbol)
        args = message[3]
      executeEPC(cmd, args)
      returnEPC(client, uid, sexp(results))
    of "return":
      raise newException(EUnexpectedCommand, "no return expected")
    of "return-error":
      raise newException(EUnexpectedCommand, "no return expected")
    of "epc-error":
      stderr.writeline("recieved epc error: " & $messageBuffer)
      raise newException(IOError, "epc error")
    of "methods":
      returnEPC(client, message[1].getNum, listEPC())
    else:
      raise newException(EUnexpectedCommand, "unexpected call: " & messageType)

proc mainCommand =
  registerPass verbosePass
  registerPass semPass
  gCmd = cmdIdeTools
  incl gGlobalOptions, optCaasEnabled
  isServing = true
  wantMainModule()
  appendStr(searchPaths, options.libpath)
  if gProjectFull.len != 0:
    # current path is always looked first for modules
    prependStr(searchPaths, gProjectPath)

  # do not stop after the first error:
  msgs.gErrorMax = high(int)

  case gMode
  of mstdin:
    compileProject()
    serveStdin()
  of mtcp:
    # until somebody accepted the connection, produce no output (logging is too
    # slow for big projects):
    msgs.writelnHook = proc (msg: string) = discard
    compileProject()
    serveTcp()
  of mepc:
    var server = newSocket()
    let port = connectToNextFreePort(server, "localhost")
    server.listen()
    echo port
    compileProject()
    serveEpc(server)

proc processCmdLine*(pass: TCmdLinePass, cmd: string) =
  var p = parseopt.initOptParser(cmd)
  while true:
    parseopt.next(p)
    case p.kind
    of cmdEnd: break
    of cmdLongoption, cmdShortOption:
      case p.key.normalize
      of "port":
        gPort = parseInt(p.val).Port
        gMode = mtcp
      of "address":
        gAddress = p.val
        gMode = mtcp
      of "stdin": gMode = mstdin
      of "epc":
        gMode = mepc
        gVerbosity = 0          # Port number gotta be first.
      of "debug":
        incl(gGlobalOptions, optIdeDebug)
      of "v2":
        suggestVersion = 2
      else: processSwitch(pass, p)
    of cmdArgument:
      options.gProjectName = unixToNativePath(p.key)
      # if processArgument(pass, p, argsCount): break

proc handleCmdLine() =
  if paramCount() == 0:
    stdout.writeline(Usage)
  else:
    processCmdLine(passCmd1, "")
    if gProjectName != "":
      try:
        gProjectFull = canonicalizePath(gProjectName)
      except OSError:
        gProjectFull = gProjectName
      var p = splitFile(gProjectFull)
      gProjectPath = p.dir
      gProjectName = p.name
    else:
      gProjectPath = getCurrentDir()

    # Find Nim's prefix dir.
    let binaryPath = findExe("nim")
    if binaryPath == "":
      raise newException(IOError,
          "Cannot find Nim standard library: Nim compiler not in PATH")
    gPrefixDir = binaryPath.splitPath().head.parentDir()

    loadConfigs(DefaultConfig) # load all config files
    # now process command line arguments again, because some options in the
    # command line can overwite the config file's settings
    extccomp.initVars()
    processCmdLine(passCmd2, "")
    mainCommand()

when false:
  proc quitCalled() {.noconv.} =
    writeStackTrace()

  addQuitProc(quitCalled)

condsyms.initDefines()
defineSymbol "nimsuggest"
handleCmdline()
