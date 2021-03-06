#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import typetraits

type
    DumperState = enum
        dBlockExplicitMapKey, dBlockImplicitMapKey, dBlockMapValue,
        dBlockInlineMap, dBlockSequenceItem, dFlowImplicitMapKey, dFlowMapValue,
        dFlowExplicitMapKey, dFlowSequenceItem, dFlowMapStart,
        dFlowSequenceStart

proc needsEscaping(scalar: string): bool {.raises: [].} =
    scalar.len == 0 or scalar[0] in ['@', '`'] or
            scalar.find({'{', '}', '[', ']', ',', '#', '-', ':', '?', '%', '"',
                         '\'', '\x0A', '\c'}) != -1

proc writeDoubleQuoted(scalar: string, s: Stream)
            {.raises: [YamlPresenterOutputError].} =
    try:
        s.write('"')
        for c in scalar:
            if c == '"':
                s.write('\\')
            s.write(c)
        s.write('"')
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = getCurrentException()
        raise e

template safeWrite(s: string or char) {.dirty.} =
    try:
        target.write(s)
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = getCurrentException()
        raise e

proc startItem(target: Stream, style: PresentationStyle, indentation: int,
               state: var DumperState, isObject: bool)
              {.raises: [YamlPresenterOutputError].} =
    try:
        case state
        of dBlockMapValue:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            if isObject or style == psCanonical:
                target.write("? ")
                state = dBlockExplicitMapKey
            else:
                state = dBlockImplicitMapKey
        of dBlockInlineMap:
            state = dBlockImplicitMapKey
        of dBlockExplicitMapKey:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            target.write(": ")
            state = dBlockMapValue
        of dBlockImplicitMapKey:
            target.write(": ")
            state = dBlockMapValue
        of dFlowExplicitMapKey:
            if style != psMinimal:
                target.write('\x0A')
                target.write(repeat(' ', indentation))
            target.write(": ")
            state = dFlowMapValue
        of dFlowMapValue:
            if (isObject and style != psMinimal) or
                    style in [psJson, psCanonical]:
                target.write(",\x0A" & repeat(' ', indentation))
                if style == psJson:
                    state = dFlowImplicitMapKey
                else:
                    target.write("? ")
                    state = dFlowExplicitMapKey
            elif isObject and style == psMinimal:
                target.write(", ? ")
                state = dFlowExplicitMapKey
            else:
                target.write(", ")
                state = dFlowImplicitMapKey
        of dFlowMapStart:
            if (isObject and style != psMinimal) or
                    style in [psJson, psCanonical]:
                target.write("\x0A" & repeat(' ', indentation))
                if style == psJson:
                    state = dFlowImplicitMapKey
                else:
                    target.write("? ")
                    state = dFlowExplicitMapKey
            else:
                state = dFlowImplicitMapKey
        of dFlowImplicitMapKey:
            target.write(": ")
            state = dFlowMapValue
        of dBlockSequenceItem:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            target.write("- ")
        of dFlowSequenceStart:
            case style
            of psMinimal, psDefault:
                discard
            of psCanonical, psJson:
                target.write('\x0A')
                target.write(repeat(' ', indentation))
            of psBlockOnly:
                discard # can never happen
            state = dFlowSequenceItem
        of dFlowSequenceItem:
            case style
            of psMinimal, psDefault:
                target.write(", ")
            of psCanonical, psJson:
                target.write(",\x0A")
                target.write(repeat(' ', indentation))
            of psBlockOnly:
                discard # can never happen
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = getCurrentException()
        raise e

proc anchorName(a: AnchorId): string {.raises: [].} =
    result = ""
    var i = int(a)
    while i >= 0:
        let j = i mod 36
        if j < 26: result.add(char(j + ord('a')))
        else: result.add(char(j + ord('0') - 26))
        i -= 36

proc writeTagAndAnchor(target: Stream, tag: TagId, tagLib: TagLibrary,
                       anchor: AnchorId) {.raises:[YamlPresenterOutputError].} =
    try:
        if tag notin [yTagQuestionMark, yTagExclamationMark]:
            let tagUri = tagLib.uri(tag)
            if tagUri.startsWith(tagLib.secondaryPrefix):
                target.write("!!")
                target.write(tagUri[18..tagUri.high])
                target.write(' ')
            elif tagUri.startsWith("!"):
                target.write(tagUri)
                target.write(' ')
            else:
                target.write("!<")
                target.write(tagUri)
                target.write("> ")
        if anchor != yAnchorNone:
            target.write("&")
            target.write(anchorName(anchor))
            target.write(' ')
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = getCurrentException()
        raise e

proc present*(s: var YamlStream, target: Stream, tagLib: TagLibrary,
              style: PresentationStyle = psDefault,
              indentationStep: int = 2) =
    var
        indentation = 0
        levels = newSeq[DumperState]()
        cached = initQueue[YamlStreamEvent]()
    
    while cached.len > 0 or not s.finished():
        let item = if cached.len > 0: cached.dequeue else: s.next()
        case item.kind
        of yamlStartDocument:
            if style != psJson:
                # TODO: tag directives
                try:
                    target.write("%YAML 1.2\x0A")
                    if tagLib.secondaryPrefix != yamlTagRepositoryPrefix:
                        target.write("%TAG !! " &
                                tagLib.secondaryPrefix & '\x0A')
                    target.write("--- ")
                except:
                    var e = newException(YamlPresenterOutputError, "")
                    e.parent = getCurrentException()
                    raise e
        of yamlScalar:
            if levels.len == 0:
                if style != psJson:
                    safeWrite('\x0A')
            else:
                startItem(target, style, indentation, levels[levels.high],
                          false)
            if style != psJson:
                writeTagAndAnchor(target,
                                  item.scalarTag, tagLib, item.scalarAnchor)
            
            if style == psJson:
                let hint = guessType(item.scalarContent)
                if item.scalarTag in [yTagQuestionMark, yTagBoolean] and
                        hint in [yTypeBoolTrue, yTypeBoolFalse]:
                    if hint == yTypeBoolTrue:
                        safeWrite("true")
                    else:
                        safeWrite("false")
                elif item.scalarTag in [yTagQuestionMark, yTagNull] and
                        hint == yTypeNull:
                    safeWrite("null")
                elif item.scalarTag in [yTagQuestionMark, yTagInteger] and
                        hint == yTypeInteger:
                    safeWrite(item.scalarContent)
                elif item.scalarTag in [yTagQuestionMark, yTagFloat] and
                        hint in [yTypeFloatInf, yTypeFloatNaN]:
                    raise newException(YamlPresenterJsonError,
                            "Infinity and not-a-number values cannot be presented as JSON!")
                elif item.scalarTag in [yTagQuestionMark, yTagFloat] and
                        hint == yTypeFloat:
                    safeWrite(item.scalarContent)
                else:
                    writeDoubleQuoted(item.scalarContent, target)
            elif style == psCanonical or item.scalarContent.needsEscaping:
                writeDoubleQuoted(item.scalarContent, target)
            else:
                safeWrite(item.scalarContent)
        of yamlAlias:
            if style == psJson:
                raise newException(YamlPresenterJsonError,
                                   "Alias not allowed in JSON output")
            assert levels.len > 0
            startItem(target, style, indentation, levels[levels.high], false)
            try:
                target.write('*')
                target.write(cast[byte]('a') + cast[byte](item.aliasTarget))
            except:
                var e = newException(YamlPresenterOutputError, "")
                e.parent = getCurrentException()
                raise e
        of yamlStartSequence:
            var nextState: DumperState
            case style
            of psDefault:
                var length = 0
                while true:
                    assert(not(s.finished()))
                    let next = s.next()
                    cached.enqueue(next)
                    case next.kind
                    of yamlScalar:
                        length += 2 + next.scalarContent.len
                    of yamlAlias:
                        length += 6
                    of yamlEndSequence:
                        break
                    else:
                        length = high(int)
                        break
                nextState = if length <= 60: dFlowSequenceStart else:
                            dBlockSequenceItem
            of psJson:
                if levels.len > 0 and levels[levels.high] in
                        [dFlowMapStart, dFlowMapValue]:
                    raise newException(YamlPresenterJsonError,
                            "Cannot have sequence as map key in JSON output!")
                nextState = dFlowSequenceStart
            of psMinimal, psCanonical:
                nextState = dFlowSequenceStart
            of psBlockOnly:
                nextState = dBlockSequenceItem 
            
            if levels.len == 0:
                if nextState == dBlockSequenceItem:
                    if style != psJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                else:
                    if style != psJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                    safeWrite('\x0A')
                    indentation += indentationStep
            else:
                startItem(target, style, indentation, levels[levels.high], true)
                if style != psJson:
                    writeTagAndAnchor(target,
                                      item.seqTag, tagLib, item.seqAnchor)
                indentation += indentationStep
            
            if nextState == dFlowSequenceStart:
                safeWrite('[')
            if levels.len > 0 and style in [psJson, psCanonical] and
                    levels[levels.high] in
                    [dBlockExplicitMapKey, dBlockMapValue,
                     dBlockImplicitMapKey, dBlockSequenceItem]:
                indentation += indentationStep
            levels.add(nextState)
        of yamlStartMap:
            var nextState: DumperState
            case style
            of psDefault:
                type MapParseState = enum
                    mpInitial, mpKey, mpValue, mpNeedBlock
                var mps: MapParseState = mpInitial
                while mps != mpNeedBlock:
                    case s.peek().kind
                    of yamlScalar, yamlAlias:
                        case mps
                        of mpInitial: mps = mpKey
                        of mpKey: mps = mpValue
                        else: mps = mpNeedBlock
                    of yamlEndMap:
                        break
                    else:
                        mps = mpNeedBlock
                nextState = if mps == mpNeedBlock: dBlockMapValue else:
                        dBlockInlineMap
            of psMinimal:
                nextState = dFlowMapStart
            of psCanonical:
                nextState = dFlowMapStart
            of psJson:
                if levels.len > 0 and levels[levels.high] in
                        [dFlowMapStart, dFlowMapValue]:
                    raise newException(YamlPresenterJsonError,
                            "Cannot have map as map key in JSON output!")
                nextState = dFlowMapStart
            of psBlockOnly:
                nextState = dBlockMapValue
            if levels.len == 0:
                if nextState == dBlockMapValue:
                    if style != psJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                else:
                    if style != psJson:
                        safeWrite('\x0A')
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                    indentation += indentationStep
            else:
                if nextState in [dBlockMapValue, dBlockImplicitMapKey]:
                    startItem(target, style, indentation, levels[levels.high],
                              true)
                    if style != psJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                else:
                    startItem(target, style, indentation, levels[levels.high],
                              true)
                    if style != psJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                indentation += indentationStep
            
            if nextState == dFlowMapStart:
                safeWrite('{')
            if levels.len > 0 and style in [psJson, psCanonical] and
                    levels[levels.high] in
                    [dBlockExplicitMapKey, dBlockMapValue,
                     dBlockImplicitMapKey, dBlockSequenceItem]:
                indentation += indentationStep
            levels.add(nextState)
            
        of yamlEndSequence:
            assert levels.len > 0
            case levels.pop()
            of dFlowSequenceItem:
                case style
                of psDefault, psMinimal, psBlockOnly:
                    safeWrite(']')
                of psJson, psCanonical:
                    indentation -= indentationStep
                    try:
                        target.write('\x0A')
                        target.write(repeat(' ', indentation))
                        target.write(']')
                    except:
                        var e = newException(YamlPresenterOutputError, "")
                        e.parent = getCurrentException()
                        raise e
                    if levels.len == 0 or levels[levels.high] notin
                            [dBlockExplicitMapKey, dBlockMapValue,
                             dBlockImplicitMapKey, dBlockSequenceItem]:
                        continue
            of dFlowSequenceStart:
                if levels.len > 0 and style in [psJson, psCanonical] and
                        levels[levels.high] in
                        [dBlockExplicitMapKey, dBlockMapValue,
                         dBlockImplicitMapKey, dBlockSequenceItem]:
                    indentation -= indentationStep
                safeWrite(']')
            of dBlockSequenceItem:
                discard
            else:
                assert false
            indentation -= indentationStep
        of yamlEndMap:
            assert levels.len > 0
            let level = levels.pop()
            case level
            of dFlowMapValue:
                case style
                of psDefault, psMinimal, psBlockOnly:
                    safeWrite('}')
                of psJson, psCanonical:
                    indentation -= indentationStep
                    try:
                        target.write('\x0A')
                        target.write(repeat(' ', indentation))
                        target.write('}')
                    except:
                        var e = newException(YamlPresenterOutputError, "")
                        e.parent = getCurrentException()
                        raise e
                    if levels.len == 0 or levels[levels.high] notin
                            [dBlockExplicitMapKey, dBlockMapValue,
                             dBlockImplicitMapKey, dBlockSequenceItem]:
                        continue
            of dFlowMapStart:
                if levels.len > 0 and style in [psJson, psCanonical] and
                        levels[levels.high] in
                        [dBlockExplicitMapKey, dBlockMapValue,
                         dBlockImplicitMapKey, dBlockSequenceItem]:
                    indentation -= indentationStep
                safeWrite('}')
            of dBlockMapValue, dBlockInlineMap:
                discard
            else:
                assert false
            indentation -= indentationStep
        of yamlEndDocument:
            if finished(s): break
            safeWrite("...\x0A")

proc transform*(input: Stream, output: Stream, style: PresentationStyle,
                indentationStep: int = 2) =
    var
        taglib = initExtendedTagLibrary()
        parser = newYamlParser(tagLib)
        events = parser.parse(input)
    try:
        if style == psCanonical:
            var specificTagEvents = iterator(): YamlStreamEvent =
                for e in events:
                    var event = e
                    case event.kind
                    of yamlStartDocument, yamlEndDocument, yamlEndMap,
                            yamlAlias, yamlEndSequence:
                        discard
                    of yamlStartMap:
                        if event.mapTag in [yTagQuestionMark,
                                            yTagExclamationMark]:
                            event.mapTag = yTagMap
                    of yamlStartSequence:
                        if event.seqTag in [yTagQuestionMark,
                                            yTagExclamationMark]:
                            event.seqTag = yTagSequence
                    of yamlScalar:
                        if event.scalarTag == yTagQuestionMark:
                            case guessType(event.scalarContent)
                            of yTypeInteger:
                                event.scalarTag = yTagInteger
                            of yTypeFloat, yTypeFloatInf, yTypeFloatNaN:
                                event.scalarTag = yTagFloat
                            of yTypeBoolTrue, yTypeBoolFalse:
                                event.scalarTag = yTagBoolean
                            of yTypeNull:
                                event.scalarTag = yTagNull
                            of yTypeUnknown:
                                event.scalarTag = yTagString
                        elif event.scalarTag == yTagExclamationMark:
                            event.scalarTag = yTagString
                    yield event
            var s = initYamlStream(specificTagEvents)
            present(s, output, tagLib, style,
                    indentationStep)
        else:
            present(events, output, tagLib, style, indentationStep)
    except YamlStreamError:
        var e = getCurrentException()
        while e.parent of YamlStreamError: e = e.parent
        if e.parent of IOError:
            raise (ref IOError)(e.parent)
        elif e.parent of YamlParserError:
            raise (ref YamlParserError)(e.parent)
        else:
            # never happens
            assert(false)
    except YamlPresenterJsonError:
        raise (ref YamlPresenterJsonError)(getCurrentException())
    except YamlPresenterOutputError:
        raise (ref YamlPresenterOutputError)(getCurrentException())