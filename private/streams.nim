proc initYamlStream*(backend: iterator(): YamlStreamEvent): YamlStream =
    result.peeked = false
    result.backend = backend

proc next*(s: var YamlStream): YamlStreamEvent =
    if s.peeked:
        s.peeked = false
        result = s.cached
    else:
        try:
            result = s.backend()
            assert(not finished(s.backend))
        except AssertionError: raise
        except YamlStreamError:
            let cur = getCurrentException()
            var e = newException(YamlStreamError, cur.msg)
            e.parent = cur.parent
            raise e
        except Exception:
            let cur = getCurrentException()
            var e = newException(YamlStreamError, cur.msg)
            e.parent = cur
            raise e

proc peek*(s: var YamlStream): YamlStreamEvent =
    if not s.peeked:
        s.cached = s.next()
        s.peeked = true
    result = s.cached

proc `peek=`*(s: var YamlStream, value: YamlStreamEvent) =
    s.cached = value
    s.peeked = true
    
proc finished*(s: var YamlStream): bool =
    if s.peeked:
        result = false
    else:
        try:
            s.cached = s.backend()
            if finished(s.backend): result = true
            else:
                s.peeked = true
                result = false
        except AssertionError: raise
        except YamlStreamError:
            let cur = getCurrentException()
            var e = newException(YamlStreamError, cur.msg)
            e.parent = cur.parent
            raise e
        except Exception:
            let cur = getCurrentException()
            var e = newException(YamlStreamError, cur.msg)
            e.parent = cur
            raise e