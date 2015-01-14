
_ = require 'lodash'

Env = require './env'

regVariable = /(\w|\$)[\$\w\d]*(\.(\w|\$)[\$\w\d]*)*/
regNumber = /^[+-\.]?[\d\.]+/

space     = type: 'control', name: 'space'
newline   = type: 'control', name: 'newline'
comma     = type: 'control', name: 'comma'
semicolon = type: 'control', name: 'semicolon'
indent    = type: 'control', name: 'indent'
unindent  = type: 'control', name: 'unindent'

S = (code, target) ->
  type: 'segment', name: code, x: target.x, y: target.y

exports.resolve = (ast) ->
  topEnv = new Env null
  topState =
    position: 'statement'
    wantReturn: false
  pos = 0
  res = transformList ast, topEnv, topState
  [
    topEnv
    res
    newline
  ]

transformExpr = (expr, env, state, pos) ->
  if _.isArray expr
    if expr.length is 0 then throw  new Error 'got empty expression'
    head = expr[0]
    insideState =
      position: 'inline'
      wantReturn: state.wantReturn
      parentLength: state.parentLength
    res = switch
      when head.text in ['+', '-', '*', '/']
        transformInfixMath expr, env, insideState
      when head.text in ['>', '==', '<', '&&', '||', '!']
        transformInfixOperator expr, env, insideState
      else
        handler = builtins[head.text]
        handler or= builtins['evaluate']
        handler expr, env, insideState, pos
    type = 'expr'
  else # token
    res = transformToken expr
    type = 'token'
  hasBlock = expr[0]?.text in ['for', 'while', 'if', '?=', '\\']
  if (state.position is 'inline') and (type is 'expr') and (not state.bracketFree)
    res = [
      type: 'control', name: '('
      res
      type: 'control', name: ')'
    ]
  if (state.position is 'inlineList') and (pos > 0)
    res = [
      comma
      space
      res
    ]
  if (state.position is 'statement')
    res = [
      newline
      res
      semicolon unless hasBlock
    ]
  if state.wantReturn and ((state.position + 1) is state.parentLength)
    res = [
      type: 'control', name: 'return '
      res
    ]
  res

transformToken = (expr) ->
  text = expr.text
  switch
    when text in ['true', 'false', 'undefined', 'null', 'continute', 'break', 'debugger']
      S text, expr
    when text[0] is ':'
      stringValue = "'#{(JSON.stringify text[1..])[1...-1]}'"
      S stringValue, expr
    when text[0] is '/'
      S "/#{text[1..]}/", expr
    when text[0].match(regNumber)?
      numberValue = parseFloat(text).toString()
      S numberValue, expr
    when text[0].match(regVariable)?
      S text, expr
    else
      throw new Error "can recognize ==#{expr.text}=="

transformInfixOperator = (expr, env, state) ->
  unless expr.length is 3
    throw new Error "infix operators accepts 2 arguments"
  head = expr[0]
  first = expr[1]
  second = expr[2]
  insideState =
    position: 'inline'
    wantReturn: no
  [
    transformExpr first, env, insideState
    space
    S head.text, head
    space
    transformExpr second, env, insideState
  ]

transformInfixMath = (expr, env, state, pos) ->
  head = expr[0]
  tail = expr[1..]
  fold = (xs, list) ->
    if list.length is 0 then return xs
    if xs.length > 0
      xs = xs.concat space
      xs = xs.concat (S head.text, head)
      xs = xs.concat space
    first = list[0]
    newXs = xs.concat first
    fold newXs, list[1..]
  insideState =
    position: 'inline'
    wantReturn: false
  fold [], (tail.map (x) -> transformExpr x, env, insideState)

transformList = (list, env, state) ->
  state.length = list.length
  list.map (expr, pos) ->
    transformExpr expr, env, state, pos

builtins =
  '=': (expr, env, state) ->
    head = expr[0]
    variable = expr[1]
    insideState =
      position: 'inline'
      wantReturn: false
      bracketFree: yes
    unless variable.text.match(regVariable)?
      throw new Error "path can not be assgined ==#{variable.text}=="
    segmentVar = S variable.text, variable
    env.registerVar segmentVar
    [
      segmentVar
      space
      S '=', head
      space
      transformExpr expr[2], env, insideState
    ]

  'evaluate': (expr, env, state) ->
    head = expr[0]
    insideState =
      position: 'inline'
      wantReturn: false
    unless head.text.match(regVariable)
      throw new Error "can not evaluate #{head.text}"
    tail = expr[1..]
    [
      S head.text, head
      S '(', head
      transformList tail, env, insideState
      S ')', head
    ]

  'array': (expr, env, state) ->
    head = expr[0]
    tail = expr[1..]
    insideState =
      position: 'inlineList'
      wantReturn: false
    [
      S '[', head
      transformList tail, env, insideState
      S ']', head
    ]

  'object': (expr, env, state) ->
    head = expr[0]
    body = expr[1..]
    insideState =
      position: 'inline'
      wantReturn: false
    pairs = body.map (pair, index) ->
      key = pair[0]
      unless _.isObject(key) and key.text[0] is ':'
        throw new Error "a key starts with :"
      value = pair[1]
      [
        newline
        S key.text[1..], key
        S ':', head
        space
        transformExpr value, env, insideState
        S ',', head unless (index + 1) is body.length
      ]
    [
      S '{', head
      indent
      pairs
      unindent
      newline
      S '}', head
    ]

  '--': (expr, env) ->
    head = expr[0]
    content = expr[1]
    unless _.isObject content
      throw new Error '-- only supports text'
    [
      S '/* ', head
      S content.text, content
      S ' */', head
    ]

  '\\': (expr, env, state) ->
    head = expr[0]
    args = expr[1]
    insideEnv = new Env env
    argsState =
      position: 'inlineList'
      wantReturn: no
    insideState =
      position: 'statement'
      wantReturn: yes
    _.flatten(args).map (x) ->
      insideEnv.markArgs x.text
    unless _.isArray args
      throw new Error 'function arguments represents in an array'
    body = expr[2...-1]
    last = expr[expr.length-1]
    [
      S 'function(', head
      transformList args, env, argsState
      S ') {', head
      indent
      insideEnv
      transformList body, insideEnv, insideState
      unindent
      newline
      S '}', head
    ]

  'new': (expr, env, state) ->
    head = expr[0]
    construct = expr[1]
    options = expr[2..]
    insideState =
      position: 'inlineList'
      wantReturn: no
    before = [
      S 'new', head
      space
      S construct.text, construct
      S '(', head
      transformList options, env, insideState
      S ')', head
    ]

  '.': (expr, env, state) ->
    head = expr[0]
    dict = expr[1]
    insideState =
      position: 'inline'
      wantReturn: no
    key = expr[2]
    [
      transformExpr dict, env, insideState
      S '[', head
      transformExpr key, env, insideState
      S ']', head
    ]

  '?': (expr, env, state) ->
    head = expr[0]
    insideState =
      position: 'inline'
      wantReturn: no
    value = transformExpr expr[1], env, insideState
    [
      S '(typeof ', head
      value
      S ' !== \'undefined\') && (', head
      value
      S ' !== null)', head
    ]

  '?=': (expr, env, state) ->
    head = expr[0]
    variable = expr[1]
    value = expr[2]
    insideState =
      position: 'inline'
      wantReturn: no
    unless variable.text.match(regVariable)?
      throw new Error "path can not be assgined ==#{variable.text}=="
    [
      S 'if (', head
      S variable.text, variable
      S ' == null) {', head
      indent
      newline
      S variable.text, variable
      space
      S '=', head
      space
      transformExpr value, env, insideState
      semicolon
      unindent
      newline
      S '}', head
    ]

  '++:': (expr, env, state) ->
    head = expr[0]
    insideState =
      position: 'inline'
      wantReturn: no
    expr[1..].map (x, index) ->
      [
        S (if index is 0 then '\'\'+ ' else ' + " " + '), head
        transformExpr x, env, insideState
      ]

  'while': (expr, env, state, pos) ->
    head = expr[0]
    cond = expr[1]
    body = expr[2..]
    condState =
      position: 'inline'
      wantReturn: no
      bracketFree: yes
    insideState =
      position: 'statement'
      wantReturn: no
    [
      S 'while (', head
      transformExpr cond, env, condState
      S ') {', head
      indent
      transformList body, env, insideState
      unindent
      newline
      S '}', head
    ]

  'for': (expr, env, state) ->
    head = expr[0]
    cond = expr[1]
    body = expr[2..]
    refVar = env.makeRefN head
    lenVar = env.makeLenN head
    condState =
      position: 'inline'
      wantReturn: no
    insideState =
      position: 'statement'
      wantReturn: false
    unless _.isArray(cond) and (cond.length is 3)
      throw new Error 'cond should an array which leng is 3'
    variable = cond[0]
    key = cond[1]
    value = cond[2]
    env.registerVar (S key.text, key)
    env.registerVar (S value.text, value)
    [
      refVar
      S ' = ', head
      transformExpr variable, env, condState
      semicolon
      newline
      S 'for (', head
      S key.text, key
      S ' = 0, ', head
      lenVar
      S ' = ', head
      S variable.text, variable
      S '.length; ', head
      S key.text, key
      S ' < ', head
      lenVar
      semicolon
      space
      S key.text, key
      S '++) {', head
      indent
      newline
      S value.text, value
      S ' = ', head
      S variable.text, value
      S '[', head
      S key.text, key
      S ']', head
      semicolon
      transformList body, env, insideState
      unindent
      newline
      S '}', head
    ]

  'range': (expr, env, state) ->
    head = expr[0]
    unless expr.length is 3
      throw new Error 'range takes two arguments'
    a = S expr[1].text, expr[1]
    b = S expr[2].text, expr[2]
    [
      S '(function() {', head
      indent
      newline
      S 'var _i, _results;', head
      newline
      S '_results = [];', head
      newline
      S 'for (var _i = ', head
      a
      S '; ', head
      a
      S ' <= ', head
      b
      S ' ? _i <= ', head
      b
      S ' : _i >= ', head
      b
      S '; ', head
      a
      S ' <= ', head
      b
      S ' ? _i++ : _i--){ _results.push(_i); }', head
      newline
      S 'return _results;', head
      unindent
      newline
      S '})()', head
    ]