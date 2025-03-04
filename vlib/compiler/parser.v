// Copyright (c) 2019 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.

module compiler

import (
	os
	strings
	compiler.x64
)

struct Parser {
	file_path      string // "/home/user/hello.v"
	file_name      string // "hello.v"
	file_platform  string // ".v", "_windows.v", "_nix.v", "_darwin.v", "_linux.v" ...
	// When p.file_pcguard != '', it contains a
	// C ifdef guard clause that must be put before
	// the #include directives in the parsed .v file
	file_pcguard   string
	v              &V
	pref           &Preferences // Preferences shared from V struct
mut:
	scanner        &Scanner
	tokens         []Token
	token_idx      int
	tok            TokenKind
	prev_tok       TokenKind
	prev_tok2      TokenKind // TODO remove these once the tokens are cached
	lit            string
	cgen           &CGen
	x64            &x64.Gen
	table          &Table
	import_table   ImportTable // Holds imports for just the file being parsed
	pass           Pass
	os             OS
	inside_const   bool
	expr_var       Var
	has_immutable_field bool
	first_immutable_field Var
	assigned_type  string // non-empty if we are in an assignment expression
	expected_type  string
	tmp_cnt        int
	builtin_mod    bool
	inside_if_expr bool
	inside_unwrapping_match_statement bool
	inside_return_expr bool
	inside_unsafe bool
	is_struct_init bool
	is_var_decl    bool
	if_expr_cnt    int
	for_expr_cnt   int // to detect whether `continue` can be used
	ptr_cast       bool
	calling_c      bool
	cur_fn         Fn
	local_vars     []Var // local function variables
	var_idx       	int
	returns        	bool
	vroot          	string
	is_c_struct_init bool
	is_empty_c_struct_init bool
	is_c_fn_call bool
	can_chash bool
	attr string
	v_script bool // "V bash", import all os functions into global space
	var_decl_name string 	// To allow declaring the variable so that it can be used in the struct initialization
	is_alloc   bool // Whether current expression resulted in an allocation
	is_const_literal bool // `1`, `2.0` etc, so that `u64_var == 0` works
	in_dispatch 	bool		// dispatching generic instance?
	is_vgen bool
	is_vweb bool
	is_sql bool
	is_js bool
	sql_i int  // $1 $2 $3
	sql_params []string // ("select * from users where id = $1", ***"100"***)
	sql_types []string // int, string and so on; see sql_params
	is_vh bool // parsing .vh file (for example `const (a int)` is allowed)
pub:
	mod            string
}

const (
	MaxModuleDepth = 4
	Reserved_Types = {
		'i8' : true, 'i16' : true, 'int' : true, 'i64' : true, 'i128' : true,
		'byte' : true, 'u16' : true, 'u32' : true, 'u64' : true, 'u128' : true,
		'f32' : true, 'f64' : true,
		'rune' : true, 'byteptr' : true, 'voidptr' : true
	}
)

// new parser from string. unique id specified in `id`.
// tip: use a hashing function to auto generate `id` from `text` eg. sha1.hexhash(text)
fn (v mut V) new_parser_from_string(text string) Parser {
	mut p := v.new_parser(new_scanner(text))
	p.scan_tokens()
	return p
}

fn (v mut V) reset_cgen_file_line_parameters(){
	v.cgen.line = 0
	v.cgen.file = ''
	v.cgen.line_directives = v.pref.is_vlines
}

fn (v mut V) new_parser_from_file(path string) Parser {
	v.reset_cgen_file_line_parameters()
	//println('new_parser("$path")')
	mut path_pcguard := ''
	mut path_platform := '.v'
	for path_ending in ['_lin.v', '_mac.v', '_win.v', '_nix.v', '_linux.v',
		'_darwin.v', '_windows.v'] {
		if path.ends_with(path_ending) {
			if path_ending == '_mac.v' {
				p := path_ending.replace('_mac.v', '_darwin.v')
				println('warning: use "$p" file name instead of "$path"')
			}	
			if path_ending == '_lin.v' {
				p := path_ending.replace('_lin.v', '_linux.v')
				println('warning: use "$p" file name instead of "$path"')
			}	
			if path_ending == '_win.v' {
				p := path_ending.replace('_win.v', '_windows.v')
				println('warning: use "$p" file name instead of "$path"')
			}	
			path_platform = path_ending
			path_pcguard = platform_postfix_to_ifdefguard( path_ending )
			break
		}
	}

	mut p := v.new_parser(new_scanner_file(path))
	p = { p|
		file_path: path,
		file_name: path.all_after(os.path_separator),
		file_platform: path_platform,
		file_pcguard: path_pcguard,
		is_vh: path.ends_with('.vh'),
		v_script: path.ends_with('.vsh')
	}
	if p.v_script {
		println('new_parser: V script')
	}
	if p.pref.building_v {
		p.scanner.should_print_relative_paths_on_error = true
	}
	//if p.pref.generating_vh {
		// Keep newlines
		//p.scanner.is_vh = true
	//}	
	p.scan_tokens()
	//p.scanner.debug_tokens()
	return p
}

// creates a new parser. most likely you will want to use
// `new_parser_file` or `new_parser_string` instead.
fn (v mut V) new_parser(scanner &Scanner) Parser {
	v.reset_cgen_file_line_parameters()
	mut p := Parser {
		scanner: scanner
		v: v
		table: v.table
		cur_fn: EmptyFn
		cgen: v.cgen
		x64: v.x64
		pref: v.pref
		os: v.os
		vroot: v.vroot
		local_vars: [Var{}].repeat(MaxLocalVars)
		import_table: new_import_table()
	}
	$if js {
		p.is_js = true
	}
	if p.pref.is_repl {
		p.scanner.should_print_line_on_error = false
		p.scanner.should_print_errors_in_color = false
		p.scanner.should_print_relative_paths_on_error = true
	}
	return p
}

fn (p mut Parser) scan_tokens() {
	for {
		res := p.scanner.scan()
		p.tokens << Token{
			tok: res.tok
			lit: res.lit
			line_nr: p.scanner.line_nr
			pos: p.scanner.pos
		}
		if res.tok == .eof {
				break
		}
	}
}

fn (p mut Parser) set_current_fn(f Fn) {
	p.cur_fn = f
	//p.cur_fn = p.table.fns[f.name]
	p.scanner.fn_name = '${f.mod}.${f.name}'
}

fn (p mut Parser) next() {
	// Generate a formatted version of this token
	// (only when vfmt compile time flag is enabled, otherwise this function
	// is not even generated)
	p.fnext()
	
	p.prev_tok2 = p.prev_tok
	p.prev_tok = p.tok
	p.scanner.prev_tok = p.tok
	if p.token_idx >= p.tokens.len {
			 p.tok = .eof
			 p.lit = ''
			 return
	}
	res := p.tokens[p.token_idx]
	p.token_idx++
	p.tok = res.tok
	p.lit = res.lit
	p.scanner.line_nr = res.line_nr
	p.cgen.line = res.line_nr
}

fn (p &Parser) peek() TokenKind {
	if p.token_idx >= p.tokens.len - 2 {
		return .eof
	}
	return p.tokens[p.token_idx].tok
	/*
	mut i := p.token_idx
	for i < p.tokens.len  {
		tok := p.tokens[i]
		if tok.tok != .mline_comment && tok.tok != .line_comment {
			return tok.tok
		}	
		i++
	}
	return .eof
	*/
}

// TODO remove dups
[inline] fn (p &Parser) prev_token() Token {
	return p.tokens[p.token_idx - 2]
}
[inline] fn (p &Parser) cur_tok() Token {
	return p.tokens[p.token_idx - 1]
}
[inline] fn (p &Parser) peek_token() Token {
	if p.token_idx >= p.tokens.len - 2 {
		return Token{ tok:.eof }
	}
	return p.tokens[p.token_idx]
}

fn (p &Parser) log(s string) {
/*
	if !p.pref.is_verbose {
		return
	}
	println(s)
*/
}

pub fn (p mut Parser) add_text(text string) {
	if p.tokens.len > 1 && p.tokens[p.tokens.len-1].tok == .eof {
		p.tokens.delete(p.tokens.len-1)
	}
	p.scanner.text = p.scanner.text + '\n' + text
	p.scan_tokens()
}

fn (p mut Parser) parse(pass Pass) {
	p.cgen.line = 0
	p.cgen.file = cescaped_path(os.realpath(p.file_path))
	/////////////////////////////////////
	p.pass = pass
	p.token_idx = 0
	p.next()
	//p.log('\nparse() run=$p.pass file=$p.file_name tok=${p.strtok()}')// , "script_file=", script_file)
	// `module main` is not required if it's a single file program
	if p.pref.is_script || p.pref.is_test {
		// User may still specify `module main`
		if p.tok == .key_module {
			p.next()
			p.fspace()
			p.mod = p.check_name()
		} else {
			p.mod = 'main'
		}
	}
	else {
		p.check(.key_module)
		p.fspace()
		p.mod = p.check_name()
	}
	//
		p.fgenln('\n')

	p.cgen.nogen = false
	if p.pref.build_mode == .build_module && p.mod != p.v.mod {
		//println('skipping $p.mod (v.mod = $p.v.mod)')
		p.cgen.nogen = true
		//defer { p.cgen.nogen = false }
	}
	p.fgenln('\n')
	p.builtin_mod = p.mod == 'builtin'
	p.can_chash = p.mod in ['ui','darwin','clipboard']// TODO tmp remove
	// Import pass - the first and the smallest pass that only analyzes imports
	// if we are a building module get the full module name from v.mod
	fq_mod := if p.pref.build_mode == .build_module && p.v.mod.ends_with(p.mod) {
		p.v.mod
	}
	// fully qualify the module name, eg base64 to encoding.base64
	else {
		p.table.qualify_module(p.mod, p.file_path)
	}
	p.table.register_module(fq_mod)
	p.mod = fq_mod

	if p.pass == .imports {
		for p.tok == .key_import && p.peek() != .key_const {
			p.imports()
		}
		if 'builtin' in p.table.imports {
			p.error('module `builtin` cannot be imported')
		}
		return
	}
	// Go through every top level token or throw a compilation error if a non-top level token is met
	for {
		match p.tok {
		.key_import {
			p.imports()
		}
		.key_enum {
			next := p.peek()
			if next == .name {
				p.enum_decl(false)
			}
			else if next == .lcbr && p.pref.translated {
				// enum without a name, only allowed in code,
				// translated from C. it's a very bad practice
				// in C as well, but is used unfortunately
				// (for example, by DOOM). such fields are
				// basically int consts
				p.enum_decl(true)
			}
		}
		.key_pub {
			next := p.peek()
			match next {
				.key_fn        {	p.fn_decl()     }
				.key_const     {	p.const_decl()  }
				.key_struct,
				.key_union,
				.key_interface {	p.struct_decl() }
				.key_enum      {	p.enum_decl(false) }
				else {
					p.error('wrong pub keyword usage')
				}
			}
		}
		.key_fn {
			p.fn_decl()
		}
		.key_type {
			p.type_decl()
		}
		.lsbr {
			// `[` can only mean an [attribute] before a function
			// or a struct definition
			p.attribute()
		}
		.key_struct, .key_interface, .key_union, .lsbr {
			p.struct_decl()
		}
		.key_const {
			p.const_decl()
		}
		.hash {
			// insert C code (only for ui module)
			// # puts("hello");
			p.chash()
		}
		.dollar {
			// $if, $else
			p.comp_time()
		}
		.key_global {
			if !p.pref.translated && !p.pref.is_live &&
				!p.builtin_mod && !p.pref.building_v &&
				p.mod != 'ui'  && !os.getwd().contains('/volt') &&
				!p.pref.enable_globals
			{
				p.error('use `v --enable-globals ...` to enable globals')
				
				//p.error('__global is only allowed in translated code')
			}
			p.next()
			p.fspace()
			name := p.check_name()
			typ := p.get_type()
			p.register_global(name, typ)
			// p.genln(p.table.cgen_name_type_pair(name, typ))
			mut g := p.table.cgen_name_type_pair(name, typ)
			if p.tok == .assign {
				p.next()
				g += ' = '
				_, expr := p.tmp_expr()
				g += expr
			}
			// p.genln('; // global')
			g += '; // global'
			if !p.cgen.nogen {
				p.cgen.consts << g
			}
			p.fgen_nl()
			if p.tok != .key_global {
				// An extra empty line to separate a block of globals
				p.fgen_nl()
			}	
		}
		.eof {
			//p.log('end of parse()')
			// TODO: check why this was added? everything seems to work
			// without it, and it's already happening in fn_decl
			// if p.pref.is_script && !p.pref.is_test {
			// 	p.set_current_fn( MainFn )
			// 	p.check_unused_variables()
			// }
			if !p.first_pass() && !p.pref.is_repl {
				p.check_unused_imports()
			}
			p.gen_fmt() // not generated unless `-d vfmt` is provided
			return
		}
		else {
			// no `fn main`, add this "global" statement to cgen.fn_main
			if p.pref.is_script && !p.pref.is_test {
				// cur_fn is empty since there was no fn main declared
				// we need to set it to save and find variables
				if p.cur_fn.name == '' {
					p.set_current_fn( MainFn )
					if p.pref.is_repl {
						if p.first_pass() {
							return
						}
						p.clear_vars()
					}
				}
				mut start := p.cgen.lines.len
				p.statement(true)
				if start > 0 && p.cgen.lines[start - 1] != '' && p.cgen.fn_main != '' {
					start--
				}
				p.genln('')
				end := p.cgen.lines.len
				lines := p.cgen.lines.slice(start, end)
				//mut line := p.cgen.fn_main + lines.join('\n')
				//line = line.trim_space()
				p.cgen.fn_main = p.cgen.fn_main + lines.join('\n')
				p.cgen.resetln('')
				for i := start; i < end; i++ {
					p.cgen.lines[i] = ''
				}
			}
			else {
				p.error('unexpected token `${p.strtok()}`')
			}
			}
		}
	}
}

fn (p mut Parser) imports() {
	p.check(.key_import)
	// `import ()`
	if p.tok == .lpar {
		p.fspace()
		p.check(.lpar)
		p.fmt_inc()
		p.fgen_nl()
		for p.tok != .rpar && p.tok != .eof {
			p.import_statement()
			p.fgen_nl()
		}
		p.fmt_dec()
		p.check(.rpar)
		p.fgenln('\n')
		return
	}
	// `import foo`
	p.import_statement()
	p.fgen_nl()
	if p.tok != .key_import {
		p.fgen_nl()
	}
}

fn (p mut Parser) import_statement() {
	p.fspace()
	if p.tok != .name {
		p.error('bad import format')
	}
	if p.peek() == .number {
		p.error('bad import format: module/submodule names cannot begin with a number')
	}
	import_tok_idx := p.token_idx-1
	mut mod := p.check_name().trim_space()
	mut mod_alias := mod
	// submodule support
	mut depth := 1
	for p.tok == .dot {
		p.check(.dot)
		submodule := p.check_name()
		mod_alias = submodule
		mod += '.' + submodule
		depth++
		if depth > MaxModuleDepth {
			p.error('module depth of $MaxModuleDepth exceeded: $mod')
		}
	}
	// aliasing (import encoding.base64 as b64)
	if p.tok == .key_as && p.peek() == .name {
		p.check(.key_as)
		mod_alias = p.check_name()
	}
	// add import to file scope import table
	p.register_import_alias(mod_alias, mod, import_tok_idx)
	// Make sure there are no duplicate imports
	if mod in p.table.imports {
		return
	}
	//p.log('adding import $mod')
	p.table.imports << mod
	p.table.register_module(mod)
}

fn (p mut Parser) const_decl() {
	//println('const decl $p.file_path')
	is_pub := p.tok == .key_pub
	if is_pub {
		p.next()
	}	
	p.inside_const = true
	p.check(.key_const)
	p.fspace()
	p.check(.lpar)
	p.fgen_nl()
	p.fmt_inc()
	for p.tok == .name {
		if p.lit == '_' && p.peek() == .assign && !p.cgen.nogen {
			p.gen_blank_identifier_assign()
			//if !p.cgen.nogen {
			p.cgen.consts_init << p.cgen.cur_line.trim_space()
			p.cgen.resetln('')
			//}
			continue
		}
		mut name := p.check_name()		// `Age = 20`
		//if !p.pref.building_v && p.mod != 'os' && contains_capital(name) {
			//p.warn('const names cannot contain uppercase letters, use snake_case instead')
		//}
		name = p.prepend_mod(name)
		mut typ := ''
		if p.is_vh {
			//println('CONST VH $p.file_path')
			// .vh files may not have const values, just types: `const (a int)`
			if p.tok == .assign {
				p.next()
				// Otherwise parse the expression to get its type,
				// but don't generate it. Const's value is generated
				// in "module.o".
				p.cgen.nogen = true
				typ = p.expression()
				p.cgen.nogen = false
			} else {
				typ = p.get_type()
			}
			p.table.register_const(name, typ, p.mod, is_pub)
			p.cgen.consts << ('extern ' +
				p.table.cgen_name_type_pair(name, typ)) + ';'
			continue // Don't generate C code when building a .vh file
		} else {
			p.check_space(.assign)
			typ = p.expression()
		}
		if p.first_pass()  && p.table.known_const(name) {
			p.error('redefinition of `$name`')
		}
		if p.first_pass() {
			p.table.register_const(name, typ, p.mod, is_pub)
		}
		// Check to see if this constant exists, and is void. If so, try and get the type again:
		if my_const := p.v.table.find_const(name) {
			if my_const.typ == 'void' {
				for i, v in p.v.table.consts {
					if v.name == name {
						p.v.table.consts[i].typ = typ
						break
					}
				}
			}
		}
		if p.pass == .main && p.cgen.nogen && p.pref.build_mode == .build_module {
			// We are building module `ui`, but are parsing `gx` right now
			// (because of nogen). We need to import gx constants with `extern`.
			//println('extern const mod=$p.mod name=$name')
			p.cgen.consts << ('extern ' +
				p.table.cgen_name_type_pair(name, typ)) + ';'
		}
		if p.pass == .main && !p.cgen.nogen {
			// TODO hack
			// cur_line has const's value right now. if it's just a number, then optimize generation:
			// output a #define so that we don't pollute the binary with unnecessary global vars
			// Do not do this when building a module, otherwise the consts
			// will not be accessible.
			if p.pref.build_mode != .build_module && is_compile_time_const(p.cgen.cur_line) {
				p.cgen.consts << '#define $name $p.cgen.cur_line'
				p.cgen.resetln('')
				p.fgen_nl()
				continue
			}
			if typ.starts_with('[') {
				p.cgen.consts << p.table.cgen_name_type_pair(name, typ) +
				' = $p.cgen.cur_line;'
			}
			else {
				p.cgen.consts << p.table.cgen_name_type_pair(name, typ) + ';'
				//println('adding to init "$name"')
				p.cgen.consts_init << '$name = $p.cgen.cur_line;'
			}
			p.cgen.resetln('')
		}
		p.fgen_nl()
	}
	p.fmt_dec()
	p.check(.rpar)
	p.inside_const = false
}

// `type myint int`
// `type onclickfn fn(voidptr) int`
fn (p mut Parser) type_decl() {
	p.check(.key_type)
	name := p.check_name()
	// V used to have 'type Foo struct', many Go users might use this syntax
	if p.tok == .key_struct {
		p.error('use `struct $name {` instead of `type $name struct {`')
	}
	parent := p.get_type2()
	nt_pair := p.table.cgen_name_type_pair(name, parent.name)
	// TODO dirty C typedef hacks for DOOM
	// Unknown type probably means it's a struct, and it's used before the struct is defined,
	// so specify "struct"
	_struct := if parent.cat != .array && parent.cat != .func &&
		!p.table.known_type(parent.name) {
		'struct'
	} else {
		''
	}
	p.gen_typedef('typedef $_struct $nt_pair; //type alias name="$name" parent=`$parent.name`')
	p.table.register_type2(Type{
		name: name
		parent: parent.name
		mod: p.mod
		cat: .alias
	})
}

// current token is `(`
fn (p mut Parser) interface_method(field_name, receiver string) &Fn {
	mut method := &Fn {
		name: field_name
		is_interface: true
		is_method: true
		receiver_typ: receiver
	}
	//p.log('is interface. field=$field_name run=$p.pass')
	p.fn_args(mut method)
	prev_tok := p.prev_token()
	cur_tok := p.cur_tok()
	// No type on the same line, this method doesn't return a type, process next
	if prev_tok.line_nr != cur_tok.line_nr {
		method.typ = 'void'
	} else {
		method.typ = p.get_type()// method return type
		//p.fspace()
		p.fgen_nl()
	}
	return method
}

fn key_to_type_cat(tok TokenKind) TypeCategory {
	match tok {
		.key_interface { return .interface_ }
		.key_struct    { return .struct_    }
		.key_union     { return .union_     }
	}
	verror('Unknown token: $tok')
	return .builtin
}

// check_name checks for a name token and returns its literal
fn (p mut Parser) check_name() string {
	name := p.lit
	p.check(.name)
	return name
}

fn (p mut Parser) check_string() string {
	s := p.lit
	p.check(.str)
	return s
}

fn (p mut Parser) check_not_reserved () {
	if Reserved_Types[p.lit] {
		p.error('`$p.lit` can\'t be used as name')
	}
}

fn (p &Parser) strtok() string {
	if p.tok == .name {
		return p.lit
	}
	if p.tok == .number {
		return p.lit
	}	
	if p.tok == .chartoken {
		return '`$p.lit`'
	}	
	if p.tok == .str {
		if p.lit.contains("'") {
			return '"$p.lit"'
		}	  else {
			return "'$p.lit'"
		}
	}
	res := p.tok.str()
	if res == '' {
		n := int(p.tok)
		return n.str()
	}
	return res
}

// same as check(), but adds a space to the formatter output
// TODO bad name
fn (p mut Parser) check_space(expected TokenKind) {
	p.fspace()
	p.check(expected)
	p.fspace()
}

fn (p mut Parser) check(expected TokenKind) {
	if p.tok != expected {
		println('check()')
		s := 'expected `${expected.str()}` but got `${p.strtok()}`'
		p.next()
		println('next token = `${p.strtok()}`')
		if p.pref.is_debug {
			print_backtrace()
		}
		p.error(s)
	}
	/*
	if expected == .rcbr {
		p.fmt_dec()
	}
	p.fgen(p.strtok())
	// vfmt: increase indentation on `{` unless it's `{}`
	if expected == .lcbr { //&& p.scanner.pos + 1 < p.scanner.text.len && p.scanner.text[p.scanner.pos + 1] != `}` {
		p.fgen_nl()
		p.fmt_inc()
	}
	*/
	p.next()

	//if p.scanner.line_comment != '' {
		//p.fgenln('// ! "$p.scanner.line_comment"')
		//p.scanner.line_comment = ''
	//}
}


[inline]
fn (p &Parser) first_pass() bool {
	return p.pass == .decl
}

// TODO return Type instead of string?
fn (p mut Parser) get_type() string {
	mut mul := false
	mut nr_muls := 0
	mut typ := ''
	// multiple returns
	if p.tok == .lpar {
		//p.warn('`()` are no longer necessary in multiple returns' +
		//'\nuse `fn foo() int, int {` instead of `fn foo() (int, int) {`')
		// if p.inside_tuple {p.error('unexpected (')}
		// p.inside_tuple = true
		p.check(.lpar)
		mut types := []string
		for {
			types << p.get_type()
			if p.tok != .comma {
				break
			}
			p.check(.comma)
		}
		p.check(.rpar)
		// p.inside_tuple = false
		typ = p.register_multi_return_stuct(types)
		return typ
	}
	// fn type
	if p.tok == .key_fn {
		mut f := Fn{name: '_', mod: p.mod}
		p.next()
		line_nr := p.scanner.line_nr
		p.fn_args(mut f)
		// Same line, it's a return type
		if p.scanner.line_nr == line_nr {
			if p.tok in [.name, .mul, .amp, .lsbr, .question, .lpar] {
				f.typ = p.get_type()
			}
			else {
				f.typ = 'void'
			}
			// println('fn return typ=$f.typ')
		}
		else {
			f.typ = 'void'
		}
		// Register anon fn type
		fn_typ := Type {
			name: f.typ_str()// 'fn (int, int) string'
			mod: p.mod
			func: f
		}
		p.table.register_type2(fn_typ)
		return f.typ_str()
	}
	// arrays ([]int)
	mut arr_level := 0
	is_question := p.tok == .question
	if is_question {
		p.check(.question)
	}
	for p.tok == .lsbr {
		p.check(.lsbr)
		// [10]int
		if p.tok == .number {
			typ += '[$p.lit]'
			p.next()
		}
		else {
			arr_level++
		}
		p.check(.rsbr)
	}
	// map[string]int
	if !p.builtin_mod && p.tok == .name && p.lit == 'map' {
		p.next()
		p.check(.lsbr)
		key_type := p.check_name()
		if key_type != 'string' {
			p.error('maps only support string keys for now')
		}
		p.check(.rsbr)
		val_type := p.get_type()// p.check_name()
		typ = 'map_$val_type'
		p.register_map(typ)
		return typ
	}
	
	// ptr/ref
	mut warn := false
	for p.tok == .mul {
		if p.first_pass() {
			warn = true
		}
		mul = true
		nr_muls++
		p.check(.mul)
	}
	if p.tok == .amp {
		mul = true
		nr_muls++
		p.check(.amp)
	}
	typ += p.lit
	// C.Struct import
	if p.lit == 'C' && p.peek() == .dot {
		p.next()
		p.check(.dot)
		typ = p.lit
	}
	else {
		if warn && p.mod != 'ui' {
			p.warn('use `&Foo` instead of `*Foo`')
		}
		// Module specified? (e.g. gx.Image)
		if p.peek() == .dot {
			// try resolve full submodule
			if !p.builtin_mod && p.import_table.known_alias(typ) {
				mod := p.import_table.resolve_alias(typ)
				if mod.contains('.') {
					typ = mod_gen_name(mod)
				}
			}
			p.next()
			p.check(.dot)
			typ += '__$p.lit'
		}
		mut t := p.table.find_type(typ)
		// "typ" not found? try "mod__typ"
		if t.name == '' && !p.builtin_mod {
			// && !p.first_pass() {
			if !typ.contains('array_') && p.mod != 'main' && !typ.contains('__') &&
				!typ.starts_with('[') {
				typ = p.prepend_mod(typ)
			}
			t = p.table.find_type(typ)
			if t.name == '' && !p.pref.translated && !p.first_pass() && !typ.starts_with('[') {
				println('get_type() bad type')
				// println('all registered types:')
				// for q in p.table.types {
				// println(q.name)
				// }
				mut t_suggest, tc_suggest := p.table.find_misspelled_type(typ, p, 0.50)
				if t_suggest.len > 0 {
					t_suggest = '. did you mean: ($tc_suggest) `$t_suggest`'
				}
				p.error('unknown type `$typ`$t_suggest')
			}
		}
		else if !t.is_public && t.mod != p.mod && !p.is_vgen && t.name != '' && !p.first_pass() {
			p.error('type `$t.name` is private')
		}	
	}
	if typ == 'void' {
		p.error('unknown type `$typ`')
	}
	if mul {
		typ += strings.repeat(`*`, nr_muls)
	}
	// Register an []array type
	if arr_level > 0 {
		// p.log('ARR TYPE="$typ" run=$p.pass')
		// We come across "[]User" etc ?
		for i := 0; i < arr_level; i++ {
			typ = 'array_$typ'
		}
		p.register_array(typ)
	}
	p.next()
	if is_question {
		typ = 'Option_$typ'
		p.table.register_type_with_parent(typ, 'Option')
	}
	// Because the code uses * to see if it's a pointer
	if typ == 'byteptr' {
		return 'byte*'
	}
	if typ == 'voidptr' {
		//if !p.builtin_mod && p.mod != 'os' && p.mod != 'gx' && p.mod != 'gg' && !p.pref.translated {
			//p.error('voidptr can only be used in unsafe code')
		//}
		return 'void*'
	}
	if typ.last_index('__') > typ.index('__') {
		p.error('2 __ in gettype(): typ="$typ"')
	}
	return typ
}

fn (p &Parser) print_tok() {
	if p.tok == .name {
		println(p.lit)
		return
	}
	if p.tok == .str {
		println('"$p.lit"')
		return
	}
	println(p.tok.str())
}

// statements() returns the type of the last statement
fn (p mut Parser) statements() string {
	//p.log('statements()')
	typ := p.statements_no_rcbr()
	if !p.inside_if_expr {
		p.genln('}')
	}
	//if p.fileis('if_expr') {
		//println('statements() ret=$typ line=$p.scanner.line_nr')
	//}
	return typ
}

fn (p mut Parser) statements_no_rcbr() string {
	p.open_scope()

	if !p.inside_if_expr {
		//p.genln('')
	}
	mut i := 0
	mut last_st_typ := ''
	for p.tok != .rcbr && p.tok != .eof {
		// println('stm: '+p.tok.str()+', next: '+p.peek().str())
		last_st_typ = p.statement(true)
		// println('last st typ=$last_st_typ')
		if !p.inside_if_expr {
			//p.genln('')// // end st tok= ${p.strtok()}')
			p.fgen_nl()
		}
		i++
		if i > 50000 {
			p.cgen.save()
			p.error('more than 50 000 statements in function `$p.cur_fn.name`')
		}
	}
		// p.next()
	p.check(.rcbr)
	//p.fmt_dec()

	p.close_scope()
	return last_st_typ
}

fn (p mut Parser) close_scope() {
	// println('close_scope level=$f.scope_level var_idx=$f.var_idx')
	// Move back `var_idx` (pointer to the end of the array) till we reach
	// the previous scope level.  This effectivly deletes (closes) current
	// scope.
	mut i := p.var_idx - 1
	for ; i >= 0; i-- {
		v := p.local_vars[i]
		if v.scope_level != p.cur_fn.scope_level {
			break
		}
		// Clean up memory, only do this if -autofree was passed for now
		if p.pref.autofree && v.is_alloc { // && !p.pref.is_test {
			mut free_fn := 'free'
			if v.typ.starts_with('array_') {
				free_fn = 'v_array_free'
			} else if v.typ == 'string' {
				free_fn = 'v_string_free'
				//if p.fileis('str.v') {
					//println('freeing str $v.name')
				//}
				continue
			}	else if v.ptr || v.typ.ends_with('*') {
				free_fn = 'v_ptr_free'
				//continue
			}	 else {
				continue
			}
			if p.returns {
				// Don't free a variable that's being returned
				if !v.is_returned && v.typ != 'FILE*' { //!v.is_c {
					prev_line := p.cgen.lines[p.cgen.lines.len-2]
					p.cgen.lines[p.cgen.lines.len-2] =
						'$free_fn($v.name); /* :) close_scope free $v.typ */' + prev_line
				}
			} else {
				p.genln('$free_fn($v.name); // close_scope free')
			}
		}
	}
	if p.cur_fn.defer_text.last() != '' {
		p.genln(p.cur_fn.defer_text.last())
		//p.cur_fn.defer_text[f] = ''
	}
	p.cur_fn.scope_level--
	p.cur_fn.defer_text = p.cur_fn.defer_text[..p.cur_fn.scope_level + 1]
	p.var_idx = i + 1
	// println('close_scope new var_idx=$f.var_idx\n')
}

fn (p mut Parser) genln(s string) {
	p.cgen.genln(s)
}

fn (p mut Parser) gen(s string) {
	p.cgen.gen(s)
}

// Generate V header from V source
fn (p mut Parser) statement(add_semi bool) string {
	p.expected_type = ''
	if p.returns && !p.is_vweb {
		p.error('unreachable code')
	}
	// if !p.in_dispatch {
		p.cgen.is_tmp = false
	// }
	tok := p.tok
	mut q := ''
	match tok {
	.name {
		next := p.peek()
		//if p.pref.is_verbose {
			//println(next.str())
		//}
		// goto_label:
		if p.peek() == .colon {
			p.fmt_dec()
			label := p.check_name()
			p.fmt_inc()
			p.genln(label + ': ;')
			p.check(.colon)
			return ''
		}
		// `a := 777`
		else if p.peek() == .decl_assign || p.peek() == .comma {
			p.check_not_reserved()
			//p.log('var decl')
			p.var_decl()
		}
		// `_ = 777`
		else if p.lit == '_' && p.peek() == .assign {
			p.gen_blank_identifier_assign()
		}
		else {
			// panic and exit count as returns since they stop the function
			if p.lit == 'panic' || p.lit == 'exit' {
				p.returns = true
			}
			// `a + 3`, `a(7)`, or just `a`
			q = p.bool_expression()
		}
	}
	.key_goto {
		p.check(.key_goto)
		p.fspace()
		label := p.check_name()
		p.genln('goto $label;')
		return ''
	}
	.key_defer {
		p.defer_st()
		return ''
	}
	.hash {
		p.chash()
		return ''
	}
	.key_unsafe {
		p.next()
		p.inside_unsafe = true
		p.check(.lcbr)
		p.genln('{')
		p.statements()
		p.inside_unsafe = false
		//p.check(.rcbr)
	}
	.dollar {
		p.comp_time()
	}
	.key_if {
		p.if_st(false, 0)
	}
	.key_for {
		p.for_st()
	}
	.key_switch {
		p.switch_statement()
	}
	.key_match {
		p.match_statement(false)
	}
	.key_mut, .key_static {
		p.var_decl()
	}
	.key_return {
		p.return_st()
	}
	.lcbr {// {} block
		p.check(.lcbr)
		if p.tok == .rcbr {
			p.error('empty statements block')
		}	
		p.genln('{')
		p.statements()
		return ''
	}
	.key_continue {
		if p.for_expr_cnt == 0 {
			p.error('`continue` statement outside `for`')
		}
		p.genln('continue')
		p.check(.key_continue)
	}
	.key_break {
		if p.for_expr_cnt == 0 {
			p.error('`break` statement outside `for`')
		}
		p.genln('break')
		p.check(.key_break)
	}
	.key_go {
		p.go_statement()
	}
	.key_assert {
		p.assert_statement()
	}
	.key_asm {
		p.inline_asm()
	}	
	else {
		// An expression as a statement
		typ := p.expression()
		if p.inside_if_expr {
		}
		else {
			p.genln('; ')
		}
		return typ
	}
	}
	// ? : uses , as statement separators
	if p.inside_if_expr && p.tok != .rcbr {
		p.gen(', ')
	}
	if add_semi && !p.inside_if_expr {
		p.genln(';')
	}
	return q
	// p.cgen.end_statement()
}

// is_map: are we in map assignment? (m[key] = val) if yes, dont generate '='
// this can be `user = ...`  or `user.field = ...`, in both cases `v` is `user`
fn (p mut Parser) assign_statement(v Var, ph int, is_map bool) {
	errtok := p.cur_tok_index()
	//p.log('assign_statement() name=$v.name tok=')
	is_vid := p.fileis('vid') // TODO remove
	tok := p.tok
	//if !v.is_mut && !v.is_arg && !p.pref.translated && !v.is_global{
	if !v.is_mut && !p.pref.translated && !v.is_global && !is_vid {
		if v.is_arg {
			if p.cur_fn.args.len > 0 && p.cur_fn.args[0].name == v.name {
				println('make the receiver `$v.name` mutable:
fn ($v.name mut $v.typ) $p.cur_fn.name (...) {
')
			}
		}
		p.error('`$v.name` is immutable')
	}
	if !v.is_changed {
		p.mark_var_changed(v)
	}
	is_str := v.typ == 'string'
	is_ustr := v.typ == 'ustring'
	match tok {
	.assign {
		if !is_map && !p.is_empty_c_struct_init {
			p.gen(' = ')
		}
	}
	.plus_assign {
		if is_str && !p.is_js {
			p.gen('= string_add($v.name, ')// TODO can't do `foo.bar += '!'`
		}
		else if is_ustr {
			p.gen('= ustring_add($v.name, ')
		}
		else {
			p.gen(' += ')
		}
	}
	else {
		p.gen(' ' + p.tok.str() + ' ')
	}
	}
	p.fspace()
	p.next()
	p.fspace()
	pos := p.cgen.cur_line.len
	expr_type := p.bool_expression()
	//if p.expected_type.starts_with('array_') {
		//p.warn('expecting array got $expr_type')
	//}
	if expr_type == 'void' {
		_, fn_name := p.is_expr_fn_call(p.token_idx-3)
		p.error_with_token_index('$fn_name() $err_used_as_value', p.token_idx-2)
	}
	// Allow `num = 4` where `num` is an `?int`
	if p.assigned_type.starts_with('Option_') &&
		expr_type == p.assigned_type['Option_'.len..] {
		expr := p.cgen.cur_line[pos..]
		left := p.cgen.cur_line[..pos]
		typ := expr_type.replace('Option_', '')
		p.cgen.resetln(left + 'opt_ok($expr, sizeof($typ))')
	}
	else if expr_type[0]==`[` {
		// assignment to a fixed_array `mut a:=[3]int a=[1,2,3]!!`
		expr := p.cgen.cur_line[pos..].all_after('{').all_before('}')
		left := p.cgen.cur_line[..pos].all_before('=')
		cline_pos := p.cgen.cur_line[pos..]
		etype := cline_pos.all_before(' {')
		if p.assigned_type != p.expected_type {
			p.error_with_token_index( 'incompatible types: $p.assigned_type != $p.expected_type', errtok)
		}
		p.cgen.resetln('memcpy( (& $left), ($etype{$expr}), sizeof( $left ) );')
	}
	// check type for <<= >>= %= ^= &= |=
	else if tok in [.left_shift_assign, .righ_shift_assign, .mod_assign, .xor_assign, .and_assign, .or_assign] {
		if !is_integer_type(p.assigned_type) {
			p.error_with_token_index( 'cannot use ${tok.str()} assignment operator on non-integer type `$p.assigned_type`', errtok)
		}
		if !is_integer_type(expr_type) {
			p.error_with_token_index( 'cannot use non-integer type `$expr_type` as ${tok.str()} argument', errtok)
		}
	}
	else if !p.builtin_mod && !p.check_types_no_throw(expr_type, p.assigned_type) {
		p.error_with_token_index( 'cannot use type `$expr_type` as type `$p.assigned_type` in assignment', errtok)
	}
	if (is_str || is_ustr) && tok == .plus_assign && !p.is_js {
		p.gen(')')
	}
	// p.assigned_var = ''
	p.assigned_type = ''
	if !v.is_used {
		p.mark_var_used(v)
	}
}

fn (p mut Parser) var_decl() {
	p.is_alloc = false
	is_mut := p.tok == .key_mut || p.prev_tok == .key_for
	is_static := p.tok == .key_static
	if p.tok == .key_mut {
		p.check(.key_mut)
		p.fspace()
	}
	if p.tok == .key_static {
		p.check(.key_static)
		p.fspace()
	}

	mut var_token_idxs := [p.cur_tok_index()]
	mut var_mut := [is_mut] // add first var mut
	mut var_names := [p.check_name()] // add first variable

	p.scanner.validate_var_name(var_names[0])
	mut new_vars := 0
	if var_names[0] != '_' && !p.known_var(var_names[0]) {
		new_vars++
	}
	// more than 1 vars (multiple returns)
	for p.tok == .comma {
		p.check(.comma)
		if p.tok == .key_mut {
			p.check(.key_mut)
			var_mut << true
		} else {
			var_mut << false
		}
		var_token_idxs << p.cur_tok_index()
		var_name := p.check_name()
		p.scanner.validate_var_name(var_name)
		if var_name != '_' && !p.known_var(var_name) {
			new_vars++
		}
		var_names << var_name
	}
	is_assign := p.tok == .assign
	is_decl_assign := p.tok == .decl_assign
	if is_assign {
		p.check_space(.assign) // =
	} else if is_decl_assign {
		p.check_space(.decl_assign) // :=
	} else {
		p.error('expected `=` or `:=`')
	}
	// all vars on left of `:=` already defined (or `_`)
	if is_decl_assign && var_names.len == 1 && var_names[0] == '_' {
		p.error_with_token_index('use `=` instead of `:=`', var_token_idxs.last())
	}
	p.var_decl_name = if var_names.len > 1 { '_V_mret_'+var_names.join('_') } else { var_names[0] }
	t := p.gen_var_decl(p.var_decl_name, is_static)
	if t == 'void' {
		_, fn_name := p.is_expr_fn_call(p.token_idx-3)
		p.error_with_token_index('$fn_name() $err_used_as_value', p.token_idx-2)
	}
	mut var_types := [t]
	// multiple returns types
	if var_names.len > 1 {
		var_types = t.replace('_V_MulRet_', '').replace('_PTR_', '*').split('_V_')
	}
	// mismatched number of return & assignment vars
	if var_names.len != var_types.len {
		mr_fn := p.cgen.cur_line.find_between('=', '(').trim_space()
		p.error_with_token_index('assignment mismatch: ${var_names.len} variables but `$mr_fn` returns $var_types.len values', var_token_idxs.last())
	}
	for i, var_name in var_names {
		var_token_idx := var_token_idxs[i]
		var_is_mut := var_mut[i]
		var_type := var_types[i]
		known_var := p.known_var(var_name)
		if var_name == '_' {
			if var_is_mut {
				p.error_with_token_index('`mut` has no effect here', var_token_idx-1)
			}
			continue
		}
		// println('var decl tok=${p.strtok()} name=type=$var_name type=$var_type ismut=$var_is_mut')
		// var decl, already exists (shadowing is not allowed)
		// Don't allow declaring a variable with the same name. Even in a child scope
		// if var_names.len == 1 && !p.builtin_mod && known_var {
		if is_decl_assign && known_var {
			p.error_with_token_index('redefinition of `$var_name`', var_token_idx)
		}
		// mut specified with assignment
		//if /*is_assign && implicit*/ known_var && var_is_mut {
		if known_var && var_is_mut {
			p.error_with_token_index('cannot specify mutability for existing var `$var_name`, only for new vars', var_token_idx)
		}
		// assignment, but var does not exist
		if is_assign && !known_var {
			suggested := p.find_misspelled_local_var(var_name, 50)
			if suggested != '' {
				p.error_with_token_index('undefined: `$var_name`. did you mean:$suggested', var_token_idx)
			}
			p.error_with_token_index('undefined: `$var_name`.', var_token_idx)
		}
		if var_name.len > 1 && contains_capital(var_name) {
			p.error_with_token_index('variable names cannot contain uppercase letters, use snake_case instead', var_token_idx)
		}
		// multiple return
		if var_names.len > 1 {
			p.gen(';\n')
			// assigment
			// if !p.builtin_mod && known_var {
			if known_var {
				v := p.find_var(var_name) or {
					p.error_with_token_index('cannot find `$var_name`', var_token_idx)
					break
				}
				p.check_types_with_token_index(var_type, v.typ, var_token_idx)
				if !v.is_mut {
					p.error_with_token_index('`$v.name` is immutable', var_token_idx)
				}
				p.mark_var_used(v)
				p.mark_var_changed(v)
				p.gen('$var_name = ${p.var_decl_name}.var_$i')
				continue
			}
			// decleration
			p.gen('$var_type $var_name = ${p.var_decl_name}.var_$i')
		}
		p.register_var(Var {
			name: var_name
			typ: var_type
			is_mut: var_is_mut
			is_alloc: p.is_alloc || var_type.starts_with('array_')
			line_nr: p.tokens[ var_token_idx ].line_nr
			token_idx: var_token_idx
		})
		//if p.fileis('str.v') {
			//if p.is_alloc { println('REG VAR IS ALLOC $name') }
		//}
	}
	p.var_decl_name = ''
	p.is_empty_c_struct_init = false
}

fn (p mut Parser) get_struct_type(name_ string, is_c bool, is_ptr bool) string {
	mut name := name_
	if is_ptr {
		name += '*'  // `&User{}` => type `User*`
	}
	if name in reserved_type_param_names {
		p.warn('name `$name` is reserved for type parameters')
	}
	p.is_c_struct_init = is_c
	return p.struct_init(name)
}

fn (p mut Parser) get_var_type(name string, is_ptr bool, deref_nr int) string {
	v := p.find_var_check_new_var(name) or { return "" }
	if name == '_' {
		p.error('cannot use `_` as value')
	}
	if is_ptr {
		p.gen('&')
	}
    else if deref_nr > 0 {
        for _ in 0..deref_nr {
        	p.gen('*')
        }
    }
	if p.pref.autofree && v.typ == 'string' && v.is_arg &&
		p.assigned_type == 'string' {
		p.warn('setting moved ' + v.typ)
		p.mark_arg_moved(v)
	}
	mut typ := p.var_expr(v)
	// *var
	if deref_nr > 0 {
		/*
		if !p.inside_unsafe  && !p.pref.building_v && p.mod != 'os' {
			p.error('dereferencing can only be done inside an `unsafe` block')
		}	
		*/
		if !typ.contains('*') && !typ.ends_with('ptr') {
			println('name="$name", t=$v.typ')
			p.error('dereferencing requires a pointer, but got `$typ`')
		}
		for _ in 0..deref_nr {
			typ = typ.replace_once('ptr', '')// TODO
			typ = typ.replace_once('*', '')// TODO
		}

	}
	// &var
	else if is_ptr {
		typ += '*'
	}
	if p.inside_return_expr {
		//println('marking $v.name returned')
		p.mark_var_returned(v)
		// v.is_returned = true // TODO modifying a local variable
		// that's not used afterwards, this should be a compilation
		// error
	}
	return typ
}

fn (p mut Parser) get_const_type(name string, is_ptr bool) string {
	c := p.table.find_const(name) or { return "" }
	if is_ptr && !c.is_global {
		p.error('cannot take the address of constant `$c.name`')
	} else if is_ptr && c.is_global {
		// c.ptr = true
		p.gen('& /*const*/ ')
	}
	if !c.is_public && c.mod != p.mod {
		p.warn('constant `$c.name` is private')
	}	
	mut typ := p.var_expr(c)
	if is_ptr {
		typ += '*'
	}
	return typ
}

fn (p mut Parser) get_c_func_type(name string) string {
	f := Fn {
		name: name
		is_c: true
	}
	p.is_c_fn_call = true
	p.fn_call(mut f, 0, '', '')
	p.is_c_fn_call = false
	// C functions must be defined with `C.fn_name() fn_type`
	cfn := p.table.find_fn(name) or {
		// Is the user trying to do `var := C.foo()` or `bar(C.foo())`
		// without declaring `foo`?
		// Do not allow it.
		if !name.starts_with('gl') && !name.starts_with('glad') {
		p.error('undefined C function `$f.name`\n' +
			'define it with `fn C.$name([args]) [return_type]`')
		}
		return 'void*'
	}
	// println("C fn $name has type $cfn.typ")
	return cfn.typ
}

fn (p mut Parser) undefined_error(name string, orig_name string) {
	name_dotted := mod_gen_name_rev(name.replace('__', '.'))
	// check for misspelled function / variable / module / type
	suggested := p.identify_typo(name)
	if suggested.len != 0 {
		p.error('undefined: `$name_dotted`. did you mean:\n$suggested\n')
	}
	// If orig_name is a mod, then printing undefined: `mod` tells us nothing
	if p.table.known_mod(orig_name) || p.import_table.known_alias(orig_name) {
		p.error('undefined: `$name_dotted` (in module `$orig_name`)')
	} else if orig_name in reserved_type_param_names {
		p.error('the letter `$orig_name` is reserved for type parameters')
	}
	p.error('undefined: `$orig_name`')
}

fn (p mut Parser) var_expr(v Var) string {
	//p.log('\nvar_expr() v.name="$v.name" v.typ="$v.typ"')
	// println('var expr is_tmp=$p.cgen.is_tmp\n')
	if !v.is_const {
		p.mark_var_used(v)
	}
	fn_ph := p.cgen.add_placeholder()
	p.expr_var = v
	p.gen(p.table.var_cgen_name(v.name))
	p.next()
	mut typ := v.typ
	// Function pointer?
	if typ.starts_with('fn ') && p.tok == .lpar {
		T := p.table.find_type(typ)
		p.gen('(')
		p.fn_call_args(mut T.func)
		p.gen(')')
		typ = T.func.typ
	}
	// users[0].name
	if p.tok == .lsbr {
		typ = p.index_expr(typ, fn_ph)
	}
	// a.b.c().d chain
	// mut dc := 0
	for p.tok ==.dot {
		if p.peek() == .key_select {
			p.next()
			return p.select_query(fn_ph)
		}
		if typ == 'pg__DB' && !p.fileis('pg.v') && p.peek() == .name &&
			!p.tokens[p.token_idx].lit.contains('exec')
		{
			p.next()
			p.insert_query(fn_ph)
			return 'void'
		}
		// println('dot #$dc')
		typ = p.dot(typ, fn_ph)
		//p.log('typ after dot=$typ')
		// print('tok after dot()')
		// p.print_tok()
		// dc++
		if p.tok == .lsbr {
			// typ = p.index_expr(typ, fn_ph, v)
		}
	}
	// `a++` and `a--`
	if p.tok == .inc || p.tok == .dec {
		if !v.is_mut && !p.pref.translated {
			p.error('`$v.name` is immutable')
		}
		if !v.is_changed {
			p.mark_var_changed(v)
		}
		if typ != 'int' && !typ.contains('*') {
			if !p.pref.translated && !is_number_type(typ) {
				p.error('cannot ++/-- value of type `$typ`')
			}
		}
		p.gen(p.tok.str())
		p.next()// ++/--
		// allow `a := c++` in translated code TODO remove once c2v handles this
		if p.pref.translated {
			//return p.index_expr(typ, fn_ph)
		}
		else {
			return typ
		}
	}
	typ = p.index_expr(typ, fn_ph)
	// TODO hack to allow `foo.bar[0] = 2`
	if p.tok == .dot {
		for p.tok == .dot {
			typ = p.dot(typ, fn_ph)
		}
		typ = p.index_expr(typ, fn_ph)
	}
	return typ
}

// user.name => `str_typ` is `User`
// user.company.name => `str_typ` is `Company`
fn (p mut Parser) dot(str_typ_ string, method_ph int) string {
	//if p.fileis('orm_test') {
		//println('ORM dot $str_typ')
	//}
	mut str_typ := str_typ_
	p.check(.dot)
	is_variadic_arg := str_typ.starts_with('varg_')
	mut typ := p.find_type(str_typ)
	if typ.name.len == 0 {
		p.error('dot(): cannot find type `$str_typ`')
	}
	if p.tok == .dollar {
		p.comptime_method_call(typ)
		return 'void'
	}
	field_name := p.lit
	if field_name == 'filter' && str_typ.starts_with('array_') {
		p.gen_array_filter(str_typ, method_ph)
		return str_typ
	}	
	else if field_name == 'map' && str_typ.starts_with('array_') {
		return p.gen_array_map(str_typ, method_ph)
	}	
	
	fname_tidx := p.cur_tok_index()
	//p.log('dot() field_name=$field_name typ=$str_typ')
	//if p.fileis('main.v') {
		//println('dot() field_name=$field_name typ=$str_typ prev_tok=${prev_tok.str()}')
	//}
	has_field := p.table.type_has_field(typ, p.table.var_cgen_name(field_name))
	mut has_method := p.table.type_has_method(typ, field_name)
	if is_variadic_arg && field_name == 'len' {
		p.gen('->$field_name')
		p.next()
		return 'int'
	}
	// generate `.str()`
	if !has_method && field_name == 'str' && typ.name.starts_with('array_') {
		p.gen_array_str(typ)
		has_method = true
	}
	if !typ.is_c && !p.is_c_fn_call && !has_field && !has_method && !p.first_pass() {
		if typ.name.starts_with('Option_') {
			opt_type := typ.name[7..]
			p.error('unhandled option type: `?$opt_type`')
		}
		//println('error in dot():')
		//println('fields:')
		//for field in typ.fields {
			//println(field.name)
		//}
		//println('methods:')
		//for field in typ.methods {
			//println(field.name)
		//}
		//println('str_typ=="$str_typ"')
		p.error_with_token_index('type `$typ.name` has no field or method `$field_name`', fname_tidx)
	}
	mut dot := '.'
	if str_typ.ends_with('*') || str_typ == 'FT_Face' { // TODO fix C ptr typedefs
		dot = dot_ptr
	}
	// field
	if has_field {
		struct_field := if typ.name != 'Option' { p.table.var_cgen_name(field_name) } else { field_name }
		field := p.table.find_field(typ, struct_field) or {
			p.error_with_token_index('missing field: $struct_field in type $typ.name', fname_tidx)
			exit(1)
		}
		if !field.is_mut && !p.has_immutable_field {
			p.has_immutable_field = true
			p.first_immutable_field = field
		}
		// Is the next token `=`, `+=` etc?  (Are we modifying the field?)
		next := p.peek()
		modifying := next.is_assign() || next == .inc || next == .dec ||
			(field.typ.starts_with('array_') && next == .left_shift)
		if !p.builtin_mod && !p.pref.translated && modifying &&
			p.has_immutable_field {
			f := p.first_immutable_field
			p.error_with_token_index('cannot modify immutable field `$f.name` (type `$f.parent_fn`)\n' +
					'declare the field with `mut:`
struct $f.parent_fn {
  mut:
	$f.name $f.typ
}
', fname_tidx)
		}
		// Don't allow `arr.data`
		if field.access_mod == .private && !p.builtin_mod && !p.pref.translated && p.mod != typ.mod && !p.is_vgen {
			// println('$typ.name :: $field.name ')
			// println(field.access_mod)
			p.error_with_token_index('cannot refer to unexported field `$struct_field` (type `$typ.name`)\n' +
					'declare the field with `pub:`
struct $typ.name {
  pub:
	$struct_field $field.typ
}
', fname_tidx)
		}
		p.gen(dot + struct_field)
		p.next()
		return field.typ
	}
	// method
	mut method := p.table.find_method(typ, field_name) or {
		p.error_with_token_index('could not find method `$field_name`', fname_tidx) // should never happen
		exit(1)
	}
	p.fn_call(mut method, method_ph, '', str_typ)
    // optional method call `a.method() or {}`, no return assignment
    is_or_else := p.tok == .key_orelse
	if !p.is_var_decl && is_or_else {
		method.typ = p.gen_handle_option_or_else(method.typ, '', method_ph)
	}
    else if !p.is_var_decl && !is_or_else && !p.inside_return_expr &&
		method.typ.starts_with('Option_') {
        opt_type := method.typ[7..]
        p.error('unhandled option type: `?$opt_type`')
    }
	// Methods returning `array` should return `array_string` etc
	if method.typ == 'array' && typ.name.starts_with('array_') {
		return typ.name
	}
	// Array methods returning `voidptr` (like `last()`) should return element type
	if method.typ == 'void*' && typ.name.starts_with('array_') {
		return typ.name[6..]
	}
	//if false && p.tok == .lsbr {
		// if is_indexer {
		//return p.index_expr(method.typ, method_ph)
	//}
	if method.typ.ends_with('*') {
		p.is_alloc = true
	}
	return method.typ
}

enum IndexType {
	noindex
	str
	map
	array
	array0
	fixed_array
	ptr
}

fn get_index_type(typ string) IndexType {
	if typ.starts_with('map_') { return .map }
	if typ == 'string' { return .str }
	if typ.starts_with('array_')	|| typ == 'array' { return .array }
	if typ == 'byte*' || typ == 'byteptr' || typ.contains('*') {
		return .ptr
	}
	if typ[0] == `[` { return .fixed_array }
	return .noindex
}

fn (p mut Parser) index_expr(typ_ string, fn_ph int) string {
	mut typ := typ_
	// a[0]
	v := p.expr_var
	//if p.fileis('fn_test.v') {
		//println('index expr typ=$typ')
		//println(v.name)
	//}
	is_variadic_arg := typ.starts_with('varg_')
	is_map := typ.starts_with('map_')
	is_str := typ == 'string'
	is_arr0 := typ.starts_with('array_')
	is_arr := is_arr0 || typ == 'array'
	is_ptr := typ == 'byte*' || typ == 'byteptr' || typ.contains('*')
	mut is_slice := false
	is_indexer := p.tok == .lsbr
	mut close_bracket := false
	index_error_tok_pos := p.token_idx
	if is_indexer {
		is_fixed_arr := typ[0] == `[`
		if !is_str && !is_arr && !is_map && !is_ptr && !is_fixed_arr && !is_variadic_arg {
			p.error('invalid operation: type `$typ` does not support indexing')
		}
		p.check(.lsbr)
		// Get element type (set `typ` to it)
		if is_str {
			typ = 'byte'
			// Direct faster access to .str[i] in builtin modules
			if p.builtin_mod || p.pref.is_bare {
				p.gen('.str[')
				close_bracket = true
			}	
			else {
				// Bounds check everywhere else
				p.gen(', ')
			}
		}
		if is_variadic_arg { typ = typ[5..] }
		if is_fixed_arr {
			// `[10]int` => `int`, `[10][3]int` => `[3]int`
			if typ.contains('][') {
				pos := typ.index_after('[', 1)
				typ = typ[pos..]
			}
			else {
				typ = typ.all_after(']')
			}
			p.gen('[')
			close_bracket = true
		}
		else if is_ptr  && !is_variadic_arg {
			// typ = 'byte'
			typ = typ.replace('*', '')
			// modify(mut []string) fix
			if !is_arr && !is_map {
				p.gen('[/*ptr!*/')
				close_bracket = true
			}
		}
		if is_arr {
			if is_arr0 {
				typ = typ[6..]
			   }
			p.gen_array_at(typ, is_arr0, fn_ph)
		}
		// map is tricky
		// need to replace "m[key] = val" with "tmp = val; map_set(&m, key, &tmp)"
		// need to replace "m[key]"       with "tmp = val; map_get(&m, key, &tmp)"
		// can only do that later once we know whether there's an "=" or not
		if is_map {
			typ = typ.replace('map_', '')
			if typ == 'map' {
				typ = 'void*'
			}
			p.gen(',')
		}
		// expression inside [ ]
		if is_arr || is_str {
			// [2..
			if p.tok != .dotdot {
				index_pos := p.cgen.cur_line.len
				T := p.table.find_type(p.expression())
				// Allows only i8-64 and byte-64 to be used when accessing an array
				if T.parent != 'int' && T.parent != 'u32' {
					p.check_types(T.name, 'int')
				}
				if p.cgen.cur_line[index_pos..].replace(' ', '').int() < 0 {
					p.error('cannot access negative array index')
				}
			}
			// [..
			else {
				p.gen('0')
			}
			if p.tok == .dotdot {
				if is_arr {
					typ = 'array_' + typ
				} else if is_str {
					typ = 'string'
				}	 else {
					p.error('slicing is supported by arrays and strings only')
				}	
				is_slice = true
				p.next()
				p.gen(',')
				// ..4]
				if p.tok != .rsbr {
					p.check_types(p.expression(), 'int')
					p.gen(', false')
				}
				// ..]
				else {
					p.gen('-1, true')
				}
			}	
		}
		else {
			T := p.table.find_type(p.expression())
			// TODO: Get the key type of the map instead of only string.
			if is_map && T.parent != 'string' {
				p.check_types(T.name, 'string')
			}
		}
		p.check(.rsbr)
		// if (is_str && p.builtin_mod) || is_ptr || is_fixed_arr && ! (is_ptr && is_arr) {
		if close_bracket {
			p.gen(']/*r$typ $v.is_mut*/')
		}
		p.expr_var = v
	}
	// accessing variadiac args
	if is_variadic_arg {
		// TODO: why was this here?
		// if p.calling_c {
		// 	p.error('you cannot currently pass varg to a C function.')
		// }
		if is_indexer {
			l := p.cgen.cur_line.trim_space()
			index_val := l.right(l.last_index(' ')).trim_space()
			p.cgen.resetln(l[..fn_ph])
			p.table.varg_access << VargAccess{
				fn_name: p.cur_fn.name,
				tok_idx: index_error_tok_pos,
				index: index_val.int()
			}
			p.cgen.set_placeholder(fn_ph, '${v.name}->args[$index_val]')
			return typ
		}
	}
	// `m[key] = val`
	// TODO move this from index_expr()
	if (p.tok == .assign && !p.is_sql) || p.tok.is_assign() {
		if is_indexer && is_str && !p.builtin_mod {
			p.error('strings are immutable')
		}
		p.assigned_type = typ
		p.expected_type = typ
		assign_pos := p.cgen.cur_line.len
		is_cao := p.tok != .assign
		p.assign_statement(v, fn_ph, is_indexer && (is_map || is_arr))
		// `m[key] = val`
		if is_indexer && (is_map || is_arr) {
			p.gen_array_set(typ, is_ptr, is_map, fn_ph, assign_pos, is_cao)
		}
		return typ
	}
	// else if p.pref.is_verbose && p.assigned_var != '' {
	// p.error('didnt assign')
	// }
	// `m[key]`. no =, just a getter
	else if (is_map || is_arr || (is_str && !p.builtin_mod)) && is_indexer {
		p.index_get(typ, fn_ph, IndexConfig{
			is_arr: is_arr
			is_map: is_map
			is_ptr: is_ptr
			is_str: is_str
			is_slice: is_slice
		})
	}
	// else if is_arr && is_indexer{}
	return typ
}

struct IndexConfig {
	is_map bool
	is_str bool
	is_ptr bool
	is_arr bool
	is_arr0 bool
	is_slice bool
}

// for debugging only
fn (p &Parser) fileis(s string) bool {
	return p.scanner.file_path.contains(s)
}

// in and dot have higher priority than `!`
fn (p mut Parser) indot_expr() string {
	ph := p.cgen.add_placeholder()
	mut typ := p.term()
	if p.tok == .dot  {
		for p.tok == .dot {
			typ = p.dot(typ, ph)
		}
	}
	// `a in [1, 2, 3]`
	// `key in map`
	if p.tok == .key_in {
		p.fspace()
		p.check(.key_in)
		p.expected_type = typ // this allows `foo in [.val1, .val2, .val3]`
		if p.tok == .lsbr {
			// a in [1,2,3] optimization => `a == 1 || a == 2 || a == 3`
			// avoids an allocation
			p.in_optimization(typ, ph)
			return 'bool'
		}
		p.fspace()
		p.gen('), ')
		arr_typ := p.expression()
		is_map := arr_typ.starts_with('map_')
		if !arr_typ.starts_with('array_') && !is_map {
			p.error('`in` requires an array/map')
		}
		T := p.table.find_type(arr_typ)
		if !is_map && !T.has_method('contains') {
			p.error('$arr_typ has no method `contains`')
		}
		// `typ` is element's type
		if is_map {
			p.cgen.set_placeholder(ph, '(_IN_MAP( (')
		}
		else {
			p.cgen.set_placeholder(ph, '(_IN($typ, (')
		}
		p.gen('))')
		return 'bool'
	}
	return typ
}

// { user | name: 'new name' }
fn (p mut Parser) assoc() string {
	// println('assoc()')
	p.next()
	name := p.check_name()
	var := p.find_var(name) or {
		p.error('unknown variable `$name`')
		exit(1)
	}
	p.mark_var_used(var)
	p.check(.pipe)
	p.gen('($var.typ){')
	mut fields := []string// track the fields user is setting, the rest will be copied from the old object
	for p.tok != .rcbr {
		field := p.check_name()
		fields << field
		p.gen('.$field = ')
		p.check(.colon)
		p.bool_expression()
		p.gen(',')
		if p.tok != .rcbr {
			p.check(.comma)
		}
		p.fgen_nl()
	}
	// Copy the rest of the fields
	T := p.table.find_type(var.typ)
	for ffield in T.fields {
		f := ffield.name
		if f in fields {
			continue
		}
		p.gen('.$f = ${name}.$f,')
	}
	p.check(.rcbr)
	p.gen('}')
	return var.typ
}

fn (p mut Parser) char_expr() {
	p.gen('\'$p.lit\'')
	p.next()
}


fn format_str(_str string) string {
	// TODO don't call replace 3 times for every string, do this in scanner.v
	mut str := _str.replace('"', '\\"')
	str = str.replace('\r\n', '\\n')
	str = str.replace('\n', '\\n')
	return str
}

fn (p mut Parser) string_expr() {
	is_raw := p.tok == .name && p.lit == 'r'
	is_cstr := p.tok == .name && p.lit == 'c'
	if is_raw || is_cstr {
		p.next()
	}
	str := p.lit
	// No ${}, just return a simple string
	if p.peek() != .dollar || is_raw {
		f := if is_raw { cescaped_path(str) } else { format_str(str) }
		// `C.puts('hi')` => `puts("hi");`
		/*
		Calling a C function sometimes requires a call to a string method
		C.fun('ssss'.to_wide()) =>  fun(string_to_wide(tos3("ssss")))
		*/
		if (p.calling_c && p.peek() != .dot) || is_cstr || (p.pref.translated && p.mod == 'main') {
			p.gen('"$f"')
		}
		else if p.is_sql {
			p.gen("'$str'")
		}
		else if p.is_js {
			p.gen('tos("$f")')
		}
		else {
			p.gen('tos3("$f")')
		}
		p.next()
		return
	}
	$if js {
		p.error('js backend does not support string formatting yet')
	}
	p.is_alloc = true // $ interpolation means there's allocation
	mut args := '"'
	mut format := '"'
	mut complex_inter := false  // for vfmt
	for p.tok == .str {
		// Add the string between %d's
		p.lit = p.lit.replace('%', '%%')
		format += format_str(p.lit)
		p.next()// skip $
		if p.tok != .dollar {
			continue
		}
		// Handle .dollar
		p.check(.dollar)
		// If there's no string after current token, it means we are in
		// a complex expression (`${...}`)
		if p.peek() != .str {
			p.fgen('{')
			complex_inter = true
		}
		// Get bool expr inside a temp var
		typ, val_ := p.tmp_expr()
		val := val_.trim_space()
		args += ', $val'
		if typ == 'string' {
			// args += '.str'
			// printf("%.*s", a.len, a.str) syntax
			args += '.len, ${val}.str'
		}
		if typ == 'ustring' {
			args += '.len, ${val}.s.str'
		}
		if typ == 'bool' {
			//args += '.len, ${val}.str'
		}
		// Custom format? ${t.hour:02d}
		custom := p.tok == .colon
		if custom {
			mut cformat := ''
			p.next()
			if p.tok == .dot {
				cformat += '.'
				p.next()
			}
			if p.tok == .minus { // support for left aligned formatting
				cformat += '-'
				p.next()
			}
			cformat += p.lit// 02
			p.next()
			fspec := p.lit // f
			cformat += fspec
			if fspec == 's' {
				//println('custom str F=$cformat | format_specifier: "$fspec" | typ: $typ ')
				if typ != 'string' {
					p.error('only V strings can be formatted with a :${cformat} format, but you have given "${val}", which has type ${typ}')
				}
				args = args.all_before_last('${val}.len, ${val}.str') + '${val}.str'
			}
			format += '%$cformat'
			p.next()
		}
		else {
			f := p.typ_to_fmt(typ, 0)
			if f == '' {
				is_array := typ.starts_with('array_')
				typ2 := p.table.find_type(typ)
				has_str_method := p.table.type_has_method(typ2, 'str')
				if is_array || has_str_method {
					if is_array && !has_str_method {
						p.gen_array_str(typ2)
					}
					tmp_var := p.get_tmp()
					p.cgen.insert_before('string $tmp_var = ${typ}_str(${val});')
					args = args.all_before_last(val) + '${tmp_var}.len, ${tmp_var}.str'
					format += '%.*s '
				}
				else {
					p.error('unhandled sprintf format "$typ" ')
				}
			}
			format += f
		}
		//println('interpolation format is: |${format}| args are: |${args}| ')
	}
	if complex_inter {
		p.fgen('}')
	}
	//p.fgen('\'')
	// println("hello %d", num) optimization.
	if p.cgen.nogen {
		return
	}
	// println: don't allocate a new string, just print	it.
	$if !windows {
		cur_line := p.cgen.cur_line.trim_space()
		if cur_line == 'println (' && p.tok != .plus {
			p.cgen.resetln(cur_line.replace('println (', 'printf('))
			p.gen('$format\\n$args')
			return
		}
	}
	// '$age'! means the user wants this to be a tmp string (uses global buffer, no allocation,
	// won't be used	again)
	// TODO remove this hack, do this automatically
	if p.tok == .not {
		p.check(.not)
		p.gen('_STR_TMP($format$args)')
	}
	else {
		// Otherwise do len counting + allocation + sprintf
		p.gen('_STR($format$args)')
	}
}

// m := map[string]int{}
// m := { 'one': 1 }
fn (p mut Parser) map_init() string {
	// m := { 'one': 1, 'two': 2 }
	mut keys_gen := '' // (string[]){tos2("one"), tos2("two")}
	mut vals_gen := '' // (int[]){1, 2}
	mut val_type := ''  // 'int'
	if p.tok == .lcbr {
		p.check(.lcbr)
		mut i := 0
		for {
			key := p.lit
			keys_gen += 'tos3("$key"), '
			p.check(.str)
			p.check(.colon)
			p.fspace()
			t, val_expr := p.tmp_expr()
			if i == 0 {
				val_type = t
			}
			i++
			if val_type != t {
				if !p.check_types_no_throw(val_type, t) {
					p.error('bad map element type `$val_type` instead of `$t`')
				}
			}
			vals_gen += '$val_expr, '
			if p.tok == .rcbr {
				p.fgen_nl()
				p.check(.rcbr)
				break
			}
			if p.tok == .comma {
				p.check(.comma)
			}
			p.fgen_nl()
		}
		p.gen('new_map_init($i, sizeof($val_type), ' +
			'(string[$i]){ $keys_gen }, ($val_type [$i]){ $vals_gen } )')
		typ := 'map_$val_type'
		p.register_map(typ)
		return typ
	}
	p.next()
	p.check(.lsbr)
	key_type := p.check_name()
	if key_type != 'string' {
		p.error('only string key maps allowed for now')
	}
	p.check(.rsbr)
	val_type = p.get_type()/// p.check_name()
	//if !p.table.known_type(val_type) {
		//p.error('map init unknown type "$val_type"')
	//}
	typ := 'map_$val_type'
	p.register_map(typ)
	p.gen('new_map(1, sizeof($val_type))')
	if p.tok == .lcbr {
		p.check(.lcbr)
		p.check(.rcbr)
		println('warning: $p.file_name:$p.scanner.line_nr ' +
		 'initializaing maps no longer requires `{}`')
	}
	return typ
}

// `nums := [1, 2, 3]`
fn (p mut Parser) array_init() string {
	expected_array_type := p.expected_type
	//if p.fileis('interface_') {
		//println('a exp='+p.expected_type)
	//}	
	p.is_alloc = true
	p.check(.lsbr)
	mut is_integer := p.tok == .number  // for `[10]int`
	// fixed length arrays with a const len: `nums := [N]int`, same as `[10]int` basically
	mut is_const_len := false
	if p.tok == .name && !p.inside_const {
		const_name := p.prepend_mod(p.lit)
		if p.table.known_const(const_name) {
			c := p.table.find_const(const_name) or {
				//p.error('unknown const `$p.lit`')
				exit(1)
			}
			if c.typ == 'int' && p.peek() == .rsbr { //&& !p.inside_const {
				is_integer = true
				is_const_len = true
			} else {
				p.error('bad fixed size array const `$p.lit`')
			}
		}
	}
	lit := p.lit
	mut typ := ''
	new_arr_ph := p.cgen.add_placeholder()
	mut i := 0
	pos := p.cgen.cur_line.len// remember cur line to fetch first number in cgen       for [0; 10]
	for p.tok != .rsbr {
		val_typ := p.bool_expression()
		// Get the type of the first expression
		if i == 0 {
			typ = val_typ
			// fixed width array initialization? (`arr := [20]byte`)
			if is_integer && p.tok == .rsbr && p.peek() == .name &&
				p.cur_tok().line_nr == p.peek_token().line_nr {
				// there is no space between `[10]` and `byte`
				// if p.cur_tok().col + p.peek_token().lit.len == p.peek_token().col {
				if p.cur_tok().pos + p.peek_token().lit.len == p.peek_token().pos {
					p.check(.rsbr)
					array_elem_typ := p.get_type()
					if !p.table.known_type(array_elem_typ) {
						p.error('bad type `$array_elem_typ`')
					}
					p.cgen.resetln('')
					//p.gen('{0}')
					p.is_alloc = false
					if is_const_len {
						return '[${mod_gen_name(p.mod)}__$lit]$array_elem_typ'
					}
					return '[$lit]$array_elem_typ'
				} else {
					p.check(.rsbr)
					typ = p.get_type()
					p.error('no space allowed between [$lit] and $typ')
				}
			}
		}
		if val_typ != typ {
			if !p.check_types_no_throw(val_typ, typ) {
				mut ok := false
				// `foo([cat, dog])` where foo is `fn foo([]Animal) {`
				// `expected_type` is `[]Animaler`
				if expected_array_type.ends_with('er') {
					if p.satisfies_interface(expected_array_type, typ, false) {
						ok = true
					}	
				}	
				if !ok {
					p.error('bad array element type `$val_typ` instead of `$typ`')
				}
			}
		}
		if p.tok != .rsbr && p.tok != .semicolon {
			p.gen(', ')
			p.check(.comma)
			p.fspace()
		}
		i++
		// Repeat (a = [0;5] )
		if i == 1 && p.tok == .semicolon {
			p.error('`[0 ; len]` syntax was removed. Use `[0].repeat(len)` instead')
		}
	}
	p.check(.rsbr)
	// type after `]`? (e.g. "[]string")
	exp_array := p.expected_type.starts_with('array_')
	if p.tok != .name && i == 0 && !exp_array {
		p.error('specify array type: `[]typ` instead of `[]`')
	}
	if p.tok == .name && i == 0 &&
		p.tokens[p.token_idx-2].line_nr == p.tokens[p.token_idx-1].line_nr { // TODO
		// vals.len == 0 {
		if exp_array {
			p.error('no need to specify the full array type here, use `[]` instead of `[]${p.expected_type[6..]}`')
		}	
		typ = p.get_type()
	} else if exp_array && i == 0 {
		// allow `known_array = []`
		typ = p.expected_type[6..]
	}	
	// ! after array => no malloc and no copy
	no_alloc := p.tok == .not
	if no_alloc {
		p.next()
	}

	// [1,2,3]!! => [3]int{1,2,3}
	is_fixed_size := p.tok == .not
	if is_fixed_size {
		p.next()
		p.gen(' }')
		if !p.first_pass() {
			// If we are defining a const array, we don't need to specify the type:
			// `a = {1,2,3}`, not `a = (int[]) {1,2,3}`
			if p.inside_const {
				p.cgen.set_placeholder(new_arr_ph, '{')
			}
			else {
				p.cgen.set_placeholder(new_arr_ph, '($typ[]) {')
			}
		}
		return '[$i]$typ'
	}
	// if ptr {
	// typ += '_ptr"
	// }
	p.gen_array_init(typ, no_alloc, new_arr_ph, i)
	typ = 'array_$typ'
	p.register_array(typ)
	return typ
}

// `f32(3)`
// tok is `f32` or `)` if `(*int)(ptr)`

fn (p mut Parser) get_tmp() string {
	p.tmp_cnt++
	return 'tmp$p.tmp_cnt'
}

fn (p mut Parser) get_tmp_counter() int {
	p.tmp_cnt++
	return p.tmp_cnt
}


fn (p mut Parser) if_st(is_expr bool, elif_depth int) string {
	if is_expr {
		//if p.fileis('if_expr') {
			//println('IF EXPR')
		//}
		p.inside_if_expr = true
		p.gen('((')
	}
	else {
		p.gen('if (')
	}
	p.next()
	p.fspace()
	// `if a := opt() { }` syntax
	if p.tok == .name && p.peek() == .decl_assign {
		p.check_not_reserved()
		option_tmp := p.get_tmp()
		var_name := p.lit
		p.next()
		p.check(.decl_assign)
		p.is_var_decl = true
		option_type, expr := p.tmp_expr()// := p.bool_expression()
		p.is_var_decl = false
		typ := option_type[7..]
		// Option_User tmp = get_user(1);
		// if (tmp.ok) {
		//   User user = *(User*)tmp.data;
		//   [statements]
		// }
		p.cgen.insert_before('$option_type $option_tmp = $expr; ')
		p.check(.lcbr)
		p.genln(option_tmp + '.ok) {')
		p.genln('$typ $var_name = *($typ*) $option_tmp . data;')
		p.register_var(Var {
			name: var_name
			typ: typ
			is_mut: false // TODO
			//is_alloc: p.is_alloc || typ.starts_with('array_')
			//line_nr: p.tokens[ var_token_idx ].line_nr
			//token_idx: var_token_idx
		})
		p.statements()
		return 'void'
	}	else {
		p.check_types(p.bool_expression(), 'bool')
	}
	if is_expr {
		p.gen(') ? (')
	}
	else {
		p.genln(') {')
	}
	p.fspace()
	p.check(.lcbr)
	mut typ := ''
	// if { if hack
	if p.tok == .key_if && p.inside_if_expr {
		typ = p.factor()
		p.next()
	}
	else {
		typ = p.statements()
	}
	if_returns := p.returns
	p.returns = false
	if p.tok == .key_else {
		if !p.inside_if_expr {
			p.fgen_nl()
		}
		p.check(.key_else)
		p.fspace()
		if p.tok == .key_if {
			if is_expr {
				p.gen(') : (')
				nested := p.if_st(is_expr, elif_depth + 1)
				nested_returns := p.returns
				p.returns = if_returns && nested_returns
				return nested
			}
			else {
				p.gen(' else ')
				nested := p.if_st(is_expr, 0)
				nested_returns := p.returns
				p.returns = if_returns && nested_returns
				return nested
			}
			// return ''
		}
		if is_expr {
			p.gen(') : (')
		}
		else {
			p.genln(' else { ')
		}
		p.check(.lcbr)
		// statements() returns the type of the last statement
		first_typ := typ
		typ = p.statements()
		p.inside_if_expr = false
		if is_expr {
			p.check_types(first_typ, typ)
			p.gen(strings.repeat(`)`, 2 * (elif_depth + 1)))
		}
		else_returns := p.returns
		p.returns = if_returns && else_returns
		return typ
	}
	p.inside_if_expr = false
	if p.fileis('test_test') {
		println('if ret typ="$typ" line=$p.scanner.line_nr')
	}
	return typ
}

fn (p mut Parser) assert_statement() {
	if p.first_pass() {
		return
	}
	p.check(.key_assert)
	p.fspace()
	tmp := p.get_tmp()
	p.gen('bool $tmp = ')
	p.check_types(p.bool_expression(), 'bool')
	nline := p.scanner.line_nr
	// TODO print "expected:  got" for failed tests
	filename := cescaped_path(p.file_path)
	cfname:=p.cur_fn.name.replace('main__', '')
	sourceline := p.scanner.line( nline - 1 ).replace('"', '\'')

	if !p.pref.is_test {
		// an assert used in a normal v program. no fancy formatting
		p.genln(';\n
/// sline: "$sourceline"
if (!$tmp) {
	g_test_fails++;
	eprintln(tos3("${filename}:${p.scanner.line_nr}: FAILED: ${cfname}()"));
	eprintln(tos3("Source: $sourceline"));
    v_panic(tos3("An assertion failed."));
	return;
} else {
	g_test_oks++;
}
')
		return
	}
	
	p.genln(';\n
if (!$tmp) {
  g_test_fails++;
  main__cb_assertion_failed(
     tos3("$filename"),
     $p.scanner.line_nr,
     tos3("$sourceline"),
     tos3("$p.cur_fn.name()")
  );
  return;
  // TODO
  // Maybe print all vars in a test function if it fails?
} else {
  g_test_oks++;
  main__cb_assertion_ok(
     tos3("$filename"),
     $p.scanner.line_nr,
     tos3("$sourceline"),
     tos3("$p.cur_fn.name()")
  );
}

')
}

fn (p mut Parser) return_st() {
	p.check(.key_return)
	p.fspace()
	deferred_text := p.get_deferred_text()
	fn_returns := p.cur_fn.typ != 'void'
	if fn_returns {
		if p.tok == .rcbr {
			p.error('`$p.cur_fn.name` needs to return `$p.cur_fn.typ`')
		}
		ph := p.cgen.add_placeholder()
		p.inside_return_expr = true
		is_none := p.tok == .key_none
		p.expected_type = p.cur_fn.typ
		mut expr_type := p.bool_expression()
		// println('$p.cur_fn.name returns type $expr_type, should be $p.cur_fn.typ')
		mut types := []string
		mut mr_values := [p.cgen.cur_line[ph..].trim_space()]
		types << expr_type
		for p.tok == .comma {
			p.check(.comma)
			typ, expr := p.tmp_expr()
			types << typ
			mr_values << expr.trim_space()
		}
		mut cur_fn_typ_chk := p.cur_fn.typ
		// multiple returns
		if types.len > 1 {
			expr_type = types.join(',')
			cur_fn_typ_chk = cur_fn_typ_chk.replace('_V_MulRet_', '').replace('_PTR_', '*').replace('_V_', ',')
			mut ret_fields := ''
			for ret_val_idx, ret_val in mr_values {
				if ret_val_idx > 0 {
					ret_fields += ','
				}
				ret_fields += '.var_$ret_val_idx=${ret_val}'
			}
			p.cgen.resetln('($p.cur_fn.typ){$ret_fields}')
		}
		p.inside_return_expr = false
		// Automatically wrap an object inside an option if the function
		// returns an option:
		// `return val` => `return opt_ok(val)`
		if p.cur_fn.typ.ends_with(expr_type) && !is_none &&
			p.cur_fn.typ.starts_with('Option_') {
			tmp := p.get_tmp()
			ret := p.cgen.cur_line[ph..]
			typ := expr_type.replace('Option_', '')
			p.cgen.resetln('$expr_type $tmp = OPTION_CAST($expr_type)($ret);')
			p.genln(deferred_text)
			p.gen('return opt_ok(&$tmp, sizeof($typ))')
		}
		else {
			ret := p.cgen.cur_line[ph..]

			if deferred_text == '' || expr_type == 'void*' {
				// no defer{} necessary?
				if expr_type == '${p.cur_fn.typ}*' {
					p.cgen.resetln('return *$ret')
				} else {
					p.cgen.resetln('return $ret')
				}
			}  else {
				tmp := p.get_tmp()
				p.cgen.resetln('$expr_type $tmp = $ret;\n')
				p.genln(deferred_text)
				p.genln('return $tmp;')
			}
		}
		p.check_types(expr_type, cur_fn_typ_chk)
	}
	else {
		// Don't allow `return val` in functions that don't return anything
		if !p.is_vweb && (p.tok == .name || p.tok == .number || p.tok == .str) {
			p.error_with_token_index('function `$p.cur_fn.name` should not return a value', p.cur_fn.fn_name_token_idx)
		}

		p.genln(deferred_text)
		if p.cur_fn.name == 'main' {
			p.gen('return 0')
		}
		else {
			p.gen('return')
		}
	}
	//p.fgenln('//ret')
	p.returns = true
}

fn (p &Parser) get_deferred_text() string {
	// @emily33901: Scoped defer
	// Check all of our defer texts to see if there is one at a higher scope level
	// The one for our current scope would be the last so any before that need to be
	// added.
	mut deferred_text := ''
	for text in p.cur_fn.defer_text {
		if text != '' {
			// In reverse order
			deferred_text = text + deferred_text
		}
	}
	return deferred_text
}

fn prepend_mod(mod, name string) string {
	return '${mod}__${name}'
}

fn (p &Parser) prepend_mod(name string) string {
	return prepend_mod(mod_gen_name(p.mod), name)
}

fn (p mut Parser) go_statement() {
	p.check(.key_go)
	p.fspace()
	mut gotoken_idx := p.cur_tok_index()
	// TODO copypasta of name_expr() ?
	if p.peek() == .dot {
		// Method
		var_name := p.lit
		v := p.find_var(var_name) or {
			return
		}
		p.mark_var_used(v)
		gotoken_idx = p.cur_tok_index()
		p.next()
		p.check(.dot)
		typ := p.table.find_type(v.typ)
		method := p.table.find_method(typ, p.lit) or {
			p.error_with_token_index('go method missing $var_name', gotoken_idx)
			return
		}
		p.async_fn_call(method, 0, var_name, v.typ)
	}
	else {
		f_name := p.lit
		// Normal function
		f := p.table.find_fn(p.prepend_mod(f_name)) or {
			println( p.table.debug_fns() )
			p.error_with_token_index('can not find function $f_name', gotoken_idx)
			return
		}
		if f.name == 'println' || f.name == 'print' {
			p.error_with_token_index('`go` cannot be used with `println`', gotoken_idx)
		}
		p.async_fn_call(f, 0, '', '')
	}
}

/*
fn (p mut Parser) register_var(v Var) {
	if v.line_nr == 0 {
		spos := p.scanner.get_scanner_pos()
		p.register_var({ v | scanner_pos: spos, line_nr: spos.line_nr })
	} else {
		p.register_var(v)
	}
}
*/

// user:=jsdecode(User, user_json_string)
fn (p mut Parser) js_decode() string {
	p.check(.name)// json
	p.check(.dot)
	op := p.check_name()
	op_token_idx := p.cur_tok_index()
	if op == 'decode' {
		// User tmp2; tmp2.foo = 0; tmp2.bar = 0;// I forgot to zero vals before => huge bug
		// Option_User tmp3 =  jsdecode_User(json_parse( s), &tmp2); ;
		// if (!tmp3 .ok) {
		// return
		// }
		// User u = *(User*) tmp3 . data;  // TODO remove this (generated in or {} block handler)
		p.check(.lpar)
		typ := p.get_type()
		p.check(.comma)
		styp, expr := p.tmp_expr()
		p.check_types(styp, 'string')
		p.check(.rpar)
		tmp := p.get_tmp()
		cjson_tmp := p.get_tmp()
		mut decl := '$typ $tmp; '
		// Init the struct
		T := p.table.find_type(typ)
		for field in T.fields {
			def_val := type_default(field.typ)
			if def_val != '' {
				decl += '${tmp}.$field.name = OPTION_CAST($field.typ) $def_val;\n'
			}
		}
		p.gen_json_for_type(T)
		decl += 'cJSON* $cjson_tmp = json__json_parse($expr);'
		p.cgen.insert_before(decl)
		// p.gen('jsdecode_$typ(json_parse($expr), &$tmp);')
		p.gen('json__jsdecode_$typ($cjson_tmp, &$tmp); cJSON_Delete($cjson_tmp);')
		opt_type := 'Option_$typ'
		p.cgen.typedefs << 'typedef Option $opt_type;'
		p.table.register_builtin(opt_type)
		return opt_type
	}
	else if op == 'encode' {
		p.check(.lpar)
		typ, expr := p.tmp_expr()
		T := p.table.find_type(typ)
		p.gen_json_for_type(T)
		p.check(.rpar)
		p.gen('json__json_print(json__jsencode_$typ($expr))')
		return 'string'
	}
	else {
		p.error_with_token_index('bad json op "$op"', op_token_idx)
	}
	return ''
}

fn (p mut Parser) attribute() {
	p.check(.lsbr)
	if p.tok == .key_if {
		// [if vfmt]
		p.next()
		p.attr = 'if ' + p.check_name()
	}	else {
		p.attr = p.check_name()
	}
	attr_token_idx := p.cur_tok_index()
	if p.tok == .colon {
		p.check(.colon)
		p.attr = p.attr + ':' + p.check_name()
	}
	p.check(.rsbr)
	p.fgen_nl()
	if p.tok == .key_fn || (p.tok == .key_pub && p.peek() == .key_fn) {
		p.fn_decl()
		p.attr = ''
		return
	}
	else if p.tok == .key_struct {
		p.struct_decl()
		p.attr = ''
		return
	}
	p.error_with_token_index('bad attribute usage', attr_token_idx)
}

fn (p mut Parser) defer_st() {
	p.check(.key_defer)
	p.check(.lcbr)

	pos := p.cgen.lines.len

	// Save everything inside the defer block to `defer_text`.
	// It will be inserted before every `return`

	// Emily: TODO: all variables that are used in this defer statement need to be evaluated when the block
	// is defined otherwise they could change over the course of the function
	// (make temps out of them)

	p.genln('{')
	p.statements()
	p.cur_fn.defer_text.last() = p.cgen.lines[pos..].join('\n') + p.cur_fn.defer_text.last()

	// Rollback p.cgen.lines
	p.cgen.lines = p.cgen.lines[..pos]
	p.cgen.resetln('')
}

fn (p mut Parser) check_and_register_used_imported_type(typ_name string) {
	us_idx := typ_name.index('__')
	if us_idx != -1 {
		arg_mod := typ_name[..us_idx]
		if p.import_table.known_alias(arg_mod) {
			p.import_table.register_used_import(arg_mod)
		}
	}
}

fn (p mut Parser) check_unused_imports() {
	// Don't run in the generated V file with `.str()`
	if p.is_vgen {
		return
	}
	mut output := ''
	for alias, mod in p.import_table.imports {
		if !p.import_table.is_used_import(alias) {
			mod_alias := if alias == mod { alias } else { '$alias ($mod)' }
			output += '\n * $mod_alias'
		}
	}
	if output == '' { return }
	 // the imports are usually at the start of the file
	p.production_error_with_token_index( 'the following imports were never used: $output', 0 )
}

fn (p mut Parser) is_expr_fn_call(start_tok_idx int) (bool, string) {
	mut expr := p.tokens[start_tok_idx-1].str()
	mut is_fn_call := p.tokens[start_tok_idx].tok == .lpar
	if !is_fn_call {
		mut i := start_tok_idx
		for (p.tokens[i].tok == .dot || p.tokens[i].tok == .name) &&
			p.tokens[i].lit != '_' && i < p.tokens.len {
			expr += p.tokens[i].str()
			i++
		}
		is_fn_call = p.tokens[i].tok == .lpar
	}
	return is_fn_call, expr
}

fn todo_remove() {
	x64.new_gen('f')
}	
