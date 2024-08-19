@license{
Copyright (c) 2018-2023, NWO-I CWI and Swat.engineering
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
}
module lang::rascal::tests::rename::Fields

import lang::rascal::tests::rename::TestUtils;
import lang::rascal::lsp::refactor::Exception;

test bool dataField() = testRenameOccurrences({0, 1}, "
    'D oneTwo = d(1, 2);
    'x = d.foo;
    ", decls = "data D = d(int foo, int baz);"
);

// TODO Implement data types properly
// test bool multipleConstructorDataField() = testRenameOccurrences({0, 1, 2}, "
//     'x = d(1, 2);
//     'y = x.foo;
//     ", decls = "data D = d(int foo) | d(int foo, int baz);"
// , cursorAtOldNameOccurrence = 1);

@expected{illegalRename}
test bool duplicateDataField() = testRename("", decls =
    "data D = d(int foo, int bar);"
);

test bool crossModuleDataFieldAtDef() = testRenameOccurrences({
    byText("Foo", "data D = a(int foo) | b(int bar);", {0}),
    byText("Main", "
    'import Foo;
    'void main() {
    '   f = a(8);
    '   g = a.foo;
    '}
    ", {0})
}, <"Foo", "foo", 0>);

test bool crossModuleDataFieldAtUse() = testRenameOccurrences({
    byText("Foo", "data D = a(int foo) | b(int bar);", {0}),
    byText("Main", "
    'import Foo;
    'void main() {
    '   f = a(8);
    '   g = a.foo;
    '}
    ", {0})
}, <"Main", "foo", 0>);

// TODO Implement data types properly
// test bool extendedDataField() = testRenameOccurrences({
//     byText("Scratch1", "
//         'data Foo = f(int foo);
//         ", {0}),
//     byText("Scratch2", "
//         'extend Scratch1;
//         'data Foo = g(int foo);
//         ", {0})
// }, <"Scratch2", "foo", 0>);

test bool relField() = testRenameOccurrences({0, 1}, "
    'rel[str foo, str baz] r = {};
    'f = r.foo;
");

test bool lrelField() = testRenameOccurrences({0, 1}, "
    'lrel[str foo, str baz] r = [];
    'f = r.foo;
");

test bool relSubscript() = testRenameOccurrences({0, 1}, "
    'rel[str foo, str baz] r = {};
    'x = r\<foo\>;
", skipCursors = {1});

test bool relSubscriptWithVar() = testRenameOccurrences({0, 2}, "
    'rel[str foo, str baz] r = {};
    'str foo = \"foo\";
    'x = r\<foo\>;
", skipCursors = {2});

test bool tupleFieldSubscriptUpdate() = testRenameOccurrences({0, 1, 2}, "
    'tuple[str foo, int baz] t = \<\"one\", 1\>;
    'u = t[foo = \"two\"];
    'v = u.foo;
");

test bool tupleFieldAccessUpdate() = testRenameOccurrences({0, 1}, "
    'tuple[str foo, int baz] t = \<\"one\", 1\>;
    't.foo = \"two\";
");

test bool similarCollectionTypes() = testRenameOccurrences({0, 1, 2, 3, 4}, "
    'rel[str foo, int baz] r = {};
    'lrel[str foo, int baz] lr = [];
    'set[tuple[str foo, int baz]] st = {};
    'list[tuple[str foo, int baz]] lt = [];
    'tuple[str foo, int baz] t = \<\"\", 0\>;
");

test bool differentRelWithSameField() = testRenameOccurrences({0, 1}, "
    'rel[str foo, int baz] r1 = {};
    'foos1 = r1.foo;
    'rel[int n, str foo] r2 = {};
    'foos2 = r2.foo;
");

test bool tupleField() = testRenameOccurrences({0, 1}, "
    'tuple[int foo] t = \<8\>;
    'y = t.foo;
");

// We would prefer an illegalRename exception here
@expected{unsupportedRename}
test bool builtinFieldSimpleType() = testRename("
    'loc l = |unknown:///|;
    'f = l.top;
", oldName = "top", newName = "summit");
// We would prefer an illegalRename exception here

@expected{unsupportedRename}
test bool builtinFieldCollectionType() = testRename("
    'loc l = |unknown:///|;
    'f = l.ls;
", oldName = "ls", newName = "contents");
