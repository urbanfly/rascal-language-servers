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
import Map;
import ParseTree;
import Relation;
import Set;
import String;

import lang::rascal::\syntax::Rascal;

import lang::rascalcore::check::Checker;
import lang::rascalcore::check::Import;
import lang::rascalcore::check::RascalConfig;

import analysis::typepal::TypePal;
import analysis::typepal::Collector;

extend lang::rascal::lsp::refactor::Exception;
import lang::rascal::lsp::refactor::Util;
import lang::rascal::lsp::refactor::WorkspaceInfo;

import analysis::diff::edits::TextEdits;

import vis::Text;

import util::FileSystem;
import util::Maybe;
import util::Monitor;
import util::Reflective;

void throwAnyErrors(list[ModuleMessages] mmsgs) {
    for (mmsg <- mmsgs) {
        throwAnyErrors(mmsg);
    }
}

void throwAnyErrors(program(_, msgs)) {
    throwAnyErrors(msgs);
}

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

private set[IllegalRenameReason] checkCausesDoubleDeclarations(WorkspaceInfo ws, set[loc] currentDefs, set[Define] newDefs, str newName) {
    // Is newName already resolvable from a scope where <current-name> is currently declared?
    rel[loc old, loc new] doubleDeclarations = {<cD, nD.defined> | <loc cD, Define nD> <- (currentDefs * newDefs)
                                                                 , isContainedIn(cD, nD.scope)
                                                                 , !rascalMayOverload({cD, nD.defined}, ws.definitions)
    };

    rel[loc old, loc new] doubleFieldDeclarations = {<cD, nD>
        | Define _: <fieldScope, _, _, fieldId(), nD, _> <- newDefs
        , loc cD <- currentDefs
        , ws.definitions[cD]?
        , Define _: <fieldScope, _, _, fieldId(), cD, _> := ws.definitions[cD]
        , fL <- ws.facts, at := ws.facts[fL]
        , acons(aadt(_, _, _), _, _) := at
        , isStrictlyContainedIn(cD, fL)
        , isStrictlyContainedIn(nD, fL)
    };

    rel[loc old, loc new] doubleTypeParamDeclarations = {<cD, nD>
        | loc cD <- currentDefs
        , ws.facts[cD]?
        , cT: aparameter(_, _) := ws.facts[cD]
        , Define fD: <_, _, _, _, _, defType(afunc(_, funcParams:/cT, _))> <- ws.defines
        , isContainedIn(cD, fD.defined)
        , loc nD <- ws.facts
        , isContainedIn(nD, fD.defined)
        , nT: aparameter(newName, _) := ws.facts[nD]
        , /nT := funcParams
    };

    return {doubleDeclaration(old, doubleDeclarations[old]) | old <- (doubleDeclarations + doubleFieldDeclarations + doubleTypeParamDeclarations).old};
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
    iUseDef = invert(ws.useDef);
    set[Capture] newUseShadowedByRename =
        {<cD, nU> | Define nD <- newDefs
                  , loc cD <- currentDefs
                  , loc cS := ws.definitions[cD].scope
                  , isContainedIn(cS, nD.scope)
                  , nU <- iUseDef[newDefs.defined]
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
      + checkCausesDoubleDeclarations(ws, currentDefs, newNameDefs, newName)
      + checkCausesCaptures(ws, m, currentDefs, currentUses, newNameDefs)
    ;
}

private str escapeName(str name) = name in getRascalReservedIdentifiers() ? "\\<name>" : name;

// Find the smallest trees of defined non-terminal type with a source location in `useDefs`
private set[loc] findNames(start[Module] m, set[loc] useDefs) {
    map[loc, loc] useDefNameAt = ();
    useDefsToDo = useDefs;
    visit(m.top) {
        case t: appl(prod(_, _, _), _): {
            if (t.src in useDefsToDo && just(nameLoc) := locationOfName(t)) {
                useDefNameAt[t.src] = nameLoc;
                useDefsToDo -= t.src;
            }
        }
    }

    if (useDefsToDo != {}) {
        throw unsupportedRename("Rename unsupported", issues={<l, "Cannot find the name for this definition in <m.src.top>."> | l <- useDefsToDo});
    }

    return range(useDefNameAt);
}

Maybe[loc] locationOfName(Name n) = just(n.src);
Maybe[loc] locationOfName(QualifiedName qn) = just((qn.names[-1]).src);
Maybe[loc] locationOfName(FunctionDeclaration f) = just(f.signature.name.src);
Maybe[loc] locationOfName(Variable v) = just(v.name.src);
Maybe[loc] locationOfName(KeywordFormal kw) = just(kw.name.src);
Maybe[loc] locationOfName(Declaration d) = just(d.name.src) when d is annotation
                                                              || d is \tag;
Maybe[loc] locationOfName(Declaration d) = locationOfName(d.user.name) when d is \alias
                                                                         || d is dataAbstract
                                                                         || d is \data;
Maybe[loc] locationOfName(TypeVar tv) = just(tv.name.src);
Maybe[loc] locationOfName(Header h) = locationOfName(h.name);
default Maybe[loc] locationOfName(Tree t) = nothing();

private tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits] computeTextEdits(WorkspaceInfo ws, start[Module] m, set[loc] defs, set[loc] uses, str name) {
    if (reasons := collectIllegalRenames(ws, m, defs, uses, name), reasons != {}) {
        return <reasons, []>;
    }

    replaceName = escapeName(name);
    return <{}, [replace(l, replaceName) | l <- findNames(m, defs + uses)]>;
}

private tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits] computeTextEdits(WorkspaceInfo ws, loc moduleLoc, set[loc] defs, set[loc] uses, str name) =
    computeTextEdits(ws, parseModuleWithSpacesCached(moduleLoc), defs, uses, name);

private bool rascalMayOverloadSameName(set[loc] defs, map[loc, Define] definitions) {
    set[str] names = {definitions[l].id | l <- defs, definitions[l]?};
    if (size(names) > 1) return false;

    map[loc, Define] potentialOverloadDefinitions = (l: d | l <- definitions, d := definitions[l], d.id in names);
    return rascalMayOverload(defs, potentialOverloadDefinitions);
}

private bool isFunctionLocalDefs(WorkspaceInfo ws, set[loc] defs) {
    for (d <- defs) {
        if (Define _: <_, _, _, _, funDef, defType(afunc(_, _, _))> <- ws.defines
          , isContainedIn(ws.definitions[d].scope, funDef)) {
            continue;
        }
        return false;
    }
    return true;
}

private bool isFunctionLocal(WorkspaceInfo ws, cursor(def(), cursorLoc, _)) =
    isFunctionLocalDefs(ws, getOverloadedDefs(ws, {cursorLoc}, rascalMayOverloadSameName));
private bool isFunctionLocal(WorkspaceInfo ws, cursor(use(), cursorLoc, _)) =
    isFunctionLocalDefs(ws, getOverloadedDefs(ws, getDefs(ws, cursorLoc), rascalMayOverloadSameName));
private bool isFunctionLocal(WorkspaceInfo _, cursor(typeParam(), _, _)) = true;
private bool isFunctionLocal(WorkspaceInfo _, cursor(collectionField(), _, _)) = false;
private bool isFunctionLocal(WorkspaceInfo _, cursor(moduleName(), _, _)) = false;
private default bool isFunctionLocal(_, _) = false;

tuple[Cursor, WorkspaceInfo] getCursor(WorkspaceInfo ws, Tree cursorT) {
    loc cursorLoc = cursorT.src;
    str cursorName = "<cursorT>";

    ws = preLoad(ws);

    rel[loc l, CursorKind kind] locsContainingCursor = {
        <l, k>
        | <just(l), k> <- {
                // Uses
                <findSmallestContaining(ws.useDef<0>, cursorLoc), use()>
                // Defs with an identifier equals the name under the cursor
              , <findSmallestContaining((ws.defines<id, defined>)[cursorName], cursorLoc), def()>
                // Type parameters
              , <findSmallestContaining({l | l <- ws.facts, aparameter(cursorName, _) := ws.facts[l]}, cursorLoc), typeParam()>
                // Collection field definitions; any location where the label equals the name under the cursor
              , <findSmallestContaining({l | l <- ws.facts, at := ws.facts[l], at.alabel == cursorName}, cursorLoc), collectionField()>
                // Collection field uses; any location which is of set or list type, where the label of the collection element equals the name under the cursor
              , <findSmallestContaining({l | l <- ws.facts, at := ws.facts[l], (at is aset || at is alist) && at.elmType.alabel? && at.elmType.alabel == cursorName}, cursorLoc), collectionField()>
                // Module name declaration, where the cursor location is in the module header
              , <flatMap(locationOfName(parseModuleWithSpacesCached(cursorLoc.top).top.header), Maybe[loc](loc nameLoc) { return isContainedIn(cursorLoc, nameLoc) ? just(nameLoc) : nothing(); }), moduleName()>
            }
    };

    if (locsContainingCursor == {}) {
        throw unsupportedRename("Cannot find type information in TPL for <cursorLoc>");
    }

    loc c = min(locsContainingCursor.l);
    Cursor cur = cursor(use(), |unknown:///|, "");
    switch (locsContainingCursor[c]) {
        case {moduleName(), *_}: {
            cur = cursor(moduleName(), c, cursorName);
        }
        case {def(), *_}: {
            // Cursor is at a definition
            cur = cursor(def(), c, cursorName);
        }
        case {use(), *_}: {
            if (d <- ws.useDef[c], just(amodule(_)) := getFact(ws, d)) {
                // Cursor is at an import
                cur = cursor(moduleName(), c, cursorName);
            } else if (u <- ws.useDef<0>, u.begin <= cursorLoc.begin && u.end > cursorLoc.end) {
                // Cursor is at a qualified name
                cur = cursor(moduleName(), c, cursorName);
            } else if (size(getDefs(ws, c) & ws.defines.defined) > 0) {
                // The cursor is at a use with corresponding definitions.
                cur = cursor(use(), c, cursorName);
            } else if (just(at) := getFact(ws, c)) {
                if (aparameter(cursorName, _) := at) {
                    // The cursor is at a type parameter
                    cur = cursor(typeParam(), c, cursorName);
                } else if (at.alabel == cursorName) {
                    // The cursor is at a collection field
                    cur = cursor(collectionField(), c, cursorName);
                }
            }
        }
        case {k}: {
            cur = cursor(k, c, cursorName);
        }
        default:
            throw unsupportedRename("Unsupported cursor type <locsContainingCursor[c]>");
    }

    if (cur.l.scheme == "unknown") throw unexpectedFailure("Could not find cursor location.");

    return <cur, ws>;
}

private bool containsName(loc l, str name) {
    // If we do not find any occurrences of the name under the cursor in a module,
    // we are not interested in it at all, and will skip loading its TPL.
    Name cursorAsName = [Name] name;
    Name escapedCursorAsName = startsWith(name, "\\") ? cursorAsName : [Name] "\\<name>";

    m = parseModuleWithSpacesCached(l);
    if (/cursorAsName := m) {
        return true;
    } else if (escapedCursorAsName != cursorAsName, /escapedCursorAsName := m) {
        return true;
    }
    return false;
}

list[DocumentEdit] renameRascalSymbol(Tree cursorT, set[loc] workspaceFolders, str newName, PathConfig(loc) getPathConfig)
    = job("renaming <cursorT> to <newName>", list[DocumentEdit](void(str, int) step) {
    loc cursorLoc = cursorT.src;
    str cursorName = "<cursorT>";

    step("collecting workspace information", 1);
    WorkspaceInfo ws = workspaceInfo(
        // Preload
        ProjectFiles() {
            return { <
                min([f | f <- workspaceFolders, isPrefixOf(f, cursorLoc)]),
                cursorLoc.top
            > };
        },
        // Full load
        ProjectFiles() {
            return { <folder, file>
                | folder <- workspaceFolders
                , PathConfig pcfg := getPathConfig(folder)
                , srcFolder <- pcfg.srcs
                , file <- find(srcFolder, "rsc")
                , file != cursorLoc.top // because we loaded that during preload
                , containsName(file, cursorName)
            };
        },
        // Load TModel for loc
        set[TModel](ProjectFiles projectFiles) {
            set[TModel] tmodels = {};

            if (projectFiles == {}) return tmodels;

            for (projectFolder <- projectFiles.projectFolder, \files := projectFiles[projectFolder]) {
                PathConfig pcfg = getPathConfig(projectFolder);
                RascalCompilerConfig ccfg = rascalCompilerConfig(pcfg)[forceCompilationTopModule = true]
                                                                      [verbose = false]
                                                                      [logPathConfig = false];
                ms = rascalTModelForLocs(toList(\files), ccfg, dummy_compile1);
                tmodels += {convertTModel2PhysicalLocs(tm) | m <- ms.tmodels, tm := ms.tmodels[m]};
            }
            return tmodels;
        }
    );

    step("analyzing name at cursor", 1);
    <cur, ws> = getCursor(ws, cursorT);

    step("loading required type information", 1);
    if (!isFunctionLocal(ws, cur)) {
        ws = loadWorkspace(ws);
    }

    step("collecting uses of \'<cursorName>\'", 1);
    <defs, uses, getRenames> = getDefsUses(ws, cur, rascalMayOverloadSameName, getPathConfig);

    rel[loc file, loc defines] defsPerFile = {<d.top, d> | d <- defs};
    rel[loc file, loc uses] usesPerFile = {<u.top, u> | u <- uses};

    set[loc] \files = defsPerFile.file + usesPerFile.file;

    step("checking rename validity", 1);
    map[loc, tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits]] moduleResults =
        (file: <reasons, edits> | file <- \files, <reasons, edits> := computeTextEdits(ws, file, defsPerFile[file], usesPerFile[file], newName));

    if (reasons := union({moduleResults[file].reasons | file <- moduleResults}), reasons != {}) {
        list[str] reasonDescs = toList({describe(r) | r <- reasons});
        throw illegalRename("Rename is not valid, because:\n - <intercalate("\n - ", reasonDescs)>", reasons);
    }

    list[DocumentEdit] changes = [changed(file, moduleResults[file].edits) | file <- moduleResults];
    list[DocumentEdit] renames = [renamed(from, to) | <from, to> <- getRenames(newName)];

    return changes + renames;
}, totalWork = 5);

//// WORKAROUNDS

// Workaround to be able to pattern match on the emulated `src` field
data Tree (loc src = |unknown:///|(0,0,<0,0>,<0,0>));
