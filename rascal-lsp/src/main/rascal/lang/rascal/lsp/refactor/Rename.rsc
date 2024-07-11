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
@bootstrapParser
module lang::rascal::lsp::refactor::Rename

/**
 * Rename refactoring
 *
 * Implements rename refactoring according to the LSP.
 * Renaming collects information generated by the typechecker for the module/workspace, finds all definitions and
 * uses matching the position of the cursor, and computes file changes needed to rename these to the user-input name.
 */

import Exception;
import IO;
import List;
import Location;
import ParseTree;
import Relation;
import Set;
import String;

import lang::rascal::\syntax::Rascal;

import lang::rascalcore::check::Import;
import lang::rascalcore::check::RascalConfig;

import analysis::typepal::TypePal;

import lang::rascal::lsp::refactor::Exception;
import lang::rascal::lsp::refactor::Util;
import lang::rascal::lsp::refactor::WorkspaceInfo;

import analysis::diff::edits::TextEdits;

import vis::Text;

import util::Maybe;
import util::Reflective;

set[IllegalRenameReason] checkLegalName(str name) {
    try {
        parse(#Name, escapeName(name));
        return {};
    } catch ParseError(_): {
        return {invalidName(name)};
    }
}

private set[IllegalRenameReason] checkDefinitionsOutsideWorkspace(WorkspaceInfo ws, set[loc] defs) =
    { definitionsOutsideWorkspace(d) | set[loc] d <- groupRangeByDomain({<f, d> | loc d <- defs, f := d.top, f notin ws.modules}) };

private set[IllegalRenameReason] checkCausesDoubleDeclarations(WorkspaceInfo ws, set[loc] currentDefs, set[Define] newDefs) {
    // Is newName already resolvable from a scope where <current-name> is currently declared?
    rel[loc old, loc new] doubleDeclarations = {<cD, nD.defined> | loc cD <- currentDefs
                                                                 , Define nD <- newDefs
                                                                 , isContainedIn(cD, nD.scope)
                                                                 , !rascalMayOverload({cD, nD.defined}, ws.definitions)
    };

    return {doubleDeclaration(old, doubleDeclarations[old]) | old <- doubleDeclarations.old};
}

private set[Define] findImplicitDefinitions(WorkspaceInfo ws, start[Module] m, set[Define] newDefs) {
    set[loc] maybeImplicitDefs = {l | /QualifiedName n := m, just(l) := locationOfName(n)};
    return {def | Define def <- newDefs, (def.idRole is variableId && def.defined in ws.useDef<0>)
                                      || (def.idRole is patternVariableId && def.defined in maybeImplicitDefs)};
}

private set[IllegalRenameReason] checkCausesCaptures(WorkspaceInfo ws, start[Module] m, set[loc] currentDefs, set[loc] currentUses, set[Define] newDefs) {
    set[Define] newNameImplicitDefs = findImplicitDefinitions(ws, m, newDefs);

    // Will this rename turn an implicit declaration of `newName` into a use of a current declaration?
    set[Capture] implicitDeclBecomesUseOfCurrentDecl =
        {<cD, nD.defined> | Define nD <- newNameImplicitDefs
                          , loc cD <- currentDefs
                          , isContainedIn(nD.defined, ws.definitions[cD].scope)
        };

    // Will this rename hide a used definition of `oldName` behind an existing definition of `newName` (shadowing)?
    set[Capture] currentUseShadowedByRename =
        {<nD.defined, cU> | Define nD <- newDefs
                          , <cU, cS> <- ident(currentUses) o ws.useDef o ws.defines<defined, scope>
                          , isContainedIn(cU, nD.scope)
                          , isStrictlyContainedIn(nD.scope, cS)
        };

    // Will this rename hide a used definition of `newName` behind a definition of `oldName` (shadowing)?
    set[Capture] newUseShadowedByRename =
        {<cD, nU> | Define nD <- newDefs
                  , nU <- invert(ws.useDef)[newDefs.defined]
                  , loc cD <- currentDefs
                  , loc cS := ws.definitions[cD].scope
                  , isContainedIn(cS, nD.scope)
                  , isContainedIn(nU, cS)
        };

    allCaptures =
        implicitDeclBecomesUseOfCurrentDecl
      + currentUseShadowedByRename
      + newUseShadowedByRename;

    return allCaptures == {} ? {} : {captureChange(allCaptures)};
}

private set[IllegalRenameReason] collectIllegalRenames(WorkspaceInfo ws, start[Module] m, set[loc] currentDefs, set[loc] currentUses, str newName) {
    set[Define] newNameDefs = {def | Define def:<_, newName, _, _, _, _> <- ws.defines};

    return
        checkLegalName(newName)
      + checkDefinitionsOutsideWorkspace(ws, currentDefs)
      + checkCausesDoubleDeclarations(ws, currentDefs, newNameDefs)
      + checkCausesCaptures(ws, m, currentDefs, currentUses, newNameDefs)
    ;
}

private str escapeName(str name) = name in getRascalReservedIdentifiers() ? "\\<name>" : name;

// Find the smallest trees of defined non-terminal type with a source location in `useDefs`
private set[loc] findNames(start[Module] m, set[loc] useDefs) {
    set[loc] names = {};
    visit(m.top) {
        case t: appl(prod(_, _, _), _): {
            if (t.src in useDefs && just(nameLoc) := locationOfName(t)) {
                names += nameLoc;
            }
        }
    }

    if (size(names) != size(useDefs)) {
        throw unsupportedRename({<l, "Cannot find the name for this definition in <m.src.top>."> | l <- useDefs - names});
    }

    return names;
}

Maybe[loc] locationOfName(Name n) = just(n.src);
Maybe[loc] locationOfName(QualifiedName qn) = just((qn.names[-1]).src);
Maybe[loc] locationOfName(FunctionDeclaration f) = just(f.signature.name.src);
Maybe[loc] locationOfName(Variable v) = just(v.name.src);
Maybe[loc] locationOfName(Declaration d) = just(d.name.src) when d is annotation
                                                              || d is \tag;
Maybe[loc] locationOfName(Declaration d) = locationOfName(d.user.name) when d is \alias
                                                                         || d is dataAbstract
                                                                         || d is \data;
Maybe[loc] locationOfName(TypeVar tv) = just(tv.name.src);
default Maybe[loc] locationOfName(Tree t) = nothing();

private tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits] computeTextEdits(WorkspaceInfo ws, start[Module] m, set[loc] defs, set[loc] uses, str name) {
    if (reasons := collectIllegalRenames(ws, m, defs, uses, name), reasons != {}) {
        return <reasons, []>;
    }

    replaceName = escapeName(name);
    return <{}, [replace(l, replaceName) | l <- findNames(m, defs + uses)]>;
}

private tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits] computeTextEdits(WorkspaceInfo ws, loc moduleLoc, set[loc] defs, set[loc] uses, str name) =
    computeTextEdits(ws, parseModuleWithSpaces(moduleLoc), defs, uses, name);

private bool rascalMayOverloadSameName(set[loc] defs, map[loc, Define] definitions) {
    set[str] names = {definitions[l].id | l <- defs, definitions[l]?};
    if (size(names) > 1) return false;

    map[loc, Define] potentialOverloadDefinitions = (l: d | l <- definitions, d := definitions[l], d.id in names);
    return rascalMayOverload(defs, potentialOverloadDefinitions);
}

private list[DocumentEdit] computeDocumentEdits(WorkspaceInfo ws, Tree cursorT, str name) {
    loc cursorLoc = cursorT.src;
    str cursorName = "<cursorT>";

    println("Cursor is at id \'<cursorName>\' at <cursorLoc>");

    cursorNamedDefs = (ws.defines<id, defined>)[cursorName];

    rel[loc l, CursorKind kind] locsContainingCursor = {
        <l, k>
        | <just(l), k> <- {
                <findSmallestContaining(ws.useDef<0>, cursorLoc), use()>
              , <findSmallestContaining(cursorNamedDefs, cursorLoc), def()>
              , <findSmallestContaining({l | l <- ws.facts, aparameter(cursorName, _) := ws.facts[l]}, cursorLoc), typeParam()>
            }
    };

    if (size(locsContainingCursor) == 0) {
        throw unsupportedRename({<cursorLoc, "Cannot find cursor in TModel">});
    }

    loc c = min(locsContainingCursor.l);
    Cursor cur = cursor(use(), |unknown:///|, "");
    switch (locsContainingCursor[c]) {
        case {def(), *_}: {
            // Cursor is at a definition
            cur = cursor(def(), c, cursorName);
        }
        case {use(), *_}: {
            if (size(getDefs(ws, c) & ws.defines.defined) > 0) {
                // The cursor is at a use with corresponding definitions.
                cur = cursor(use(), c, cursorName);
            } else if (ws.facts[c]? && aparameter(cursorName, _) := ws.facts[c]) {
                // The cursor is at a type parameter
                cur = cursor(typeParam(), c, cursorName);
            } else {
                fail;
            }
        }
        case {k}: {
            cur = cursor(k, c, cursorName);
        }
        default:
            throw unsupportedRename({<c, "Unsupported cursor type: <locsContainingCursor[c]>">});
    }

    if (cur.l.scheme == "unknown") throw unexpectedFailure("Could not find cursor location.");

    <defs, uses> = getDefsUses(ws, cur, rascalMayOverloadSameName);

    rel[loc file, loc defines] defsPerFile = {<d.top, d> | d <- defs};
    rel[loc file, loc uses] usesPerFile = {<u.top, u> | u <- uses};

    files = defsPerFile.file + usesPerFile.file;
    map[loc, tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits]] moduleResults =
        (file: <reasons, edits> | file <- files, <reasons, edits> := computeTextEdits(ws, file, defsPerFile[file], usesPerFile[file], name));

    if (reasons := union({moduleResults[file].reasons | file <- moduleResults}), reasons != {}) {
        throw illegalRename(cur, reasons);
    }

    list[DocumentEdit] changes = [changed(file, moduleResults[file].edits) | file <- moduleResults];

    // TODO If the cursor was a module name, we need to rename files as well
    list[DocumentEdit] renames = [];

    return changes + renames;
}

list[DocumentEdit] renameRascalSymbol(Tree cursor, set[loc] workspaceFolders, PathConfig pcfg, str newName) {
    WorkspaceInfo ws = gatherWorkspaceInfo(workspaceFolders, pcfg);
    return computeDocumentEdits(ws, cursor, newName);
}

//// WORKAROUNDS

// Workaround to be able to pattern match on the emulated `src` field
data Tree (loc src = |unknown:///|(0,0,<0,0>,<0,0>));
