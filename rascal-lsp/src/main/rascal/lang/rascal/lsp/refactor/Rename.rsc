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

// Rascal compiler-specific extension
void throwAnyErrors(list[ModuleMessages] mmsgs) {
    for (mmsg <- mmsgs) {
        throwAnyErrors(mmsg);
    }
}

// Rascal compiler-specific extension
void throwAnyErrors(program(_, msgs)) {
    throwAnyErrors(msgs);
}

set[IllegalRenameReason] rascalCheckLegalName(str name) {
    try {
        parse(#Name, rascalEscapeName(name));
        return {};
    } catch ParseError(_): {
        return {invalidName(name)};
    }
}

private set[IllegalRenameReason] rascalCheckDefinitionsOutsideWorkspace(WorkspaceInfo ws, set[loc] defs) =
    { definitionsOutsideWorkspace(d) | set[loc] d <- groupRangeByDomain({<f, d> | loc d <- defs, f := d.top, f notin ws.sourceFiles}) };

private set[IllegalRenameReason] rascalCheckCausesDoubleDeclarations(WorkspaceInfo ws, set[loc] currentDefs, set[Define] newDefs, str newName) {
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

private set[IllegalRenameReason] rascalCheckCausesCaptures(WorkspaceInfo ws, start[Module] m, set[loc] currentDefs, set[loc] currentUses, set[Define] newDefs) {
    set[Define] rascalFindImplicitDefinitions(WorkspaceInfo ws, start[Module] m, set[Define] newDefs) {
        set[loc] maybeImplicitDefs = {l | /QualifiedName n := m, just(l) := rascalLocationOfName(n)};
        return {def | Define def <- newDefs, (def.idRole is variableId && def.defined in ws.useDef<0>)
                                        || (def.idRole is patternVariableId && def.defined in maybeImplicitDefs)};
    }

    set[Define] newNameImplicitDefs = rascalFindImplicitDefinitions(ws, m, newDefs);

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
                  , loc cD <- currentDefs
                  , loc cS := ws.definitions[cD].scope
                  , isContainedIn(cS, nD.scope)
                  , nU <- defUse(ws)[newDefs.defined]
                  , isContainedIn(nU, cS)
        };

    allCaptures =
        implicitDeclBecomesUseOfCurrentDecl
      + currentUseShadowedByRename
      + newUseShadowedByRename;

    return allCaptures == {} ? {} : {captureChange(allCaptures)};
}

private set[IllegalRenameReason] rascalCollectIllegalRenames(WorkspaceInfo ws, start[Module] m, set[loc] currentDefs, set[loc] currentUses, str newName) {
    set[Define] newNameDefs = {def | Define def:<_, newName, _, _, _, _> <- ws.defines};

    return
        rascalCheckLegalName(newName)
      + rascalCheckDefinitionsOutsideWorkspace(ws, currentDefs)
      + rascalCheckCausesDoubleDeclarations(ws, currentDefs, newNameDefs, newName)
      + rascalCheckCausesCaptures(ws, m, currentDefs, currentUses, newNameDefs)
    ;
}

private str rascalEscapeName(str name) = name in getRascalReservedIdentifiers() ? "\\<name>" : name;

// Find the smallest trees of defined non-terminal type with a source location in `useDefs`
private set[loc] rascalFindNamesInUseDefs(start[Module] m, set[loc] useDefs) {
    map[loc, loc] useDefNameAt = ();
    useDefsToDo = useDefs;
    visit(m.top) {
        case t: appl(prod(_, _, _), _): {
            if (t.src in useDefsToDo && just(nameLoc) := rascalLocationOfName(t)) {
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

Maybe[loc] rascalLocationOfName(Name n) = just(n.src);
Maybe[loc] rascalLocationOfName(QualifiedName qn) = just((qn.names[-1]).src);
Maybe[loc] rascalLocationOfName(FunctionDeclaration f) = just(f.signature.name.src);
Maybe[loc] rascalLocationOfName(Variable v) = just(v.name.src);
Maybe[loc] rascalLocationOfName(KeywordFormal kw) = just(kw.name.src);
Maybe[loc] rascalLocationOfName(Declaration d) = just(d.name.src) when d is annotation
                                                              || d is \tag;
Maybe[loc] rascalLocationOfName(Declaration d) = rascalLocationOfName(d.user.name) when d is \alias
                                                                         || d is dataAbstract
                                                                         || d is \data;
Maybe[loc] rascalLocationOfName(TypeVar tv) = just(tv.name.src);
Maybe[loc] rascalLocationOfName(Header h) = rascalLocationOfName(h.name);
default Maybe[loc] rascalLocationOfName(Tree t) = nothing();

private tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits] computeTextEdits(WorkspaceInfo ws, start[Module] m, set[loc] defs, set[loc] uses, str name) {
    if (reasons := rascalCollectIllegalRenames(ws, m, defs, uses, name), reasons != {}) {
        return <reasons, []>;
    }

    replaceName = rascalEscapeName(name);
    return <{}, [replace(l, replaceName) | l <- rascalFindNamesInUseDefs(m, defs + uses)]>;
}

private tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits] computeTextEdits(WorkspaceInfo ws, loc moduleLoc, set[loc] defs, set[loc] uses, str name) =
    computeTextEdits(ws, parseModuleWithSpacesCached(moduleLoc), defs, uses, name);

private bool rascalMayOverloadSameName(set[loc] defs, map[loc, Define] definitions) {
    set[str] names = {definitions[l].id | l <- defs, definitions[l]?};
    if (size(names) > 1) return false;

    map[loc, Define] potentialOverloadDefinitions = (l: d | l <- definitions, d := definitions[l], d.id in names);
    return rascalMayOverload(defs, potentialOverloadDefinitions);
}

private bool rascalIsFunctionLocalDefs(WorkspaceInfo ws, set[loc] defs) {
    for (d <- defs) {
        if (Define _: <_, _, _, _, funDef, defType(afunc(_, _, _))> <- ws.defines
          , isContainedIn(ws.definitions[d].scope, funDef)) {
            continue;
        }
        return false;
    }
    return true;
}

private bool rascalIsFunctionLocal(WorkspaceInfo ws, cursor(def(), cursorLoc, _)) =
    rascalIsFunctionLocalDefs(ws, rascalGetOverloadedDefs(ws, {cursorLoc}, rascalMayOverloadSameName));
private bool rascalIsFunctionLocal(WorkspaceInfo ws, cursor(use(), cursorLoc, _)) =
    rascalIsFunctionLocalDefs(ws, rascalGetOverloadedDefs(ws, getDefs(ws, cursorLoc), rascalMayOverloadSameName));
private bool rascalIsFunctionLocal(WorkspaceInfo _, cursor(typeParam(), _, _)) = true;
private default bool rascalIsFunctionLocal(_, _) = false;

private Define rascalGetADTDefinition(WorkspaceInfo ws, AType lhsType, loc lhs) {
    rel[loc, Define] definitionsRel = toRel(ws.definitions);
    if (printlnExpD("Is constructor type [<lhsType>]: ", rascalIsConstructorType(lhsType))
      , Define cons: <_, _, _, constructorId(), _, _> <- printlnExpD("Reachable defs (from lhs): ", definitionsRel[rascalReachableDefs(ws, printlnExpD("Defs of lhs: ", getDefs(ws, lhs)) + lhs)])
      , AType consAdtType := cons.defInfo.atype.adt
      , Define adt: <_, _, _, dataId(), _, defType(consAdtType)> <- printlnExpD("Reachable defs (from constructor def): ", definitionsRel[rascalReachableDefs(ws, {cons.defined})])
      , isContainedIn(cons.defined, adt.defined)) { // Probably need to follow import paths here as well
        return adt;
    } else if (rascalIsDataType(lhsType)
             , Define ctr:<_, _, _, constructorId(), _, defType(acons(lhsType, _, _))> <- definitionsRel[rascalReachableDefs(ws, getDefs(ws, lhs))]
             , Define adt:<_, _, _, dataId(), _, defType(lhsType)> <- definitionsRel[rascalReachableDefs(ws, {ctr.defined})]
             , isContainedIn(ctr.defined, adt.defined)) {
        return adt;
    }

    throw "Unknown LHS type <lhsType>";
}

bool rascalAdtHasCommonKeywordField(str fieldName, Define _:<_, _, _, dataId(), _, DefInfo defInfo>) {
    if (defInfo.commonKeywordFields?) {
        for ((KeywordFormal) `<Type _> <Name kwName> = <Expression _>` <- defInfo.commonKeywordFields, "<kwName>" == fieldName) {
            return true;
        }
    }
    return false;
}

bool rascalConsHasKeywordField(str fieldName, Define _:<_, _, _, constructorId(), _, defType(acons(_, _, kwFields))>) {
    for (kwField(_, fieldName, _) <- kwFields) return true;
    return false;
}

bool rascalConsHasField(str fieldName, Define _:<_, _, _, constructorId(), _, defType(acons(_, fields, _))>) {
    for (field <- fields) {
        if (field.alabel == fieldName) return true;
    }
    return false;
}

tuple[Cursor, WorkspaceInfo] rascalGetCursor(WorkspaceInfo ws, Tree cursorT) {
    loc cursorLoc = cursorT.src;
    str cursorName = "<cursorT>";

    ws = preLoad(ws);

    rel[loc field, loc container] fields = {<fieldLoc, containerLoc>
        | /Tree t := parseModuleWithSpacesCached(cursorLoc.top)
        , just(<containerLoc, fieldLocs>) := rascalGetFieldLocs(cursorName, t)
        , loc fieldLoc <- fieldLocs
    };

    rel[loc kw, loc container] keywords = {<kwLoc, containerLoc>
        | /Tree t := parseModuleWithSpacesCached(cursorLoc.top)
        , just(<containerLoc, kwLocs>) := rascalGetKeywordLocs(cursorName, t)
        , loc kwLoc <- kwLocs
    };

    Maybe[loc] smallestFieldContainingCursor = findSmallestContaining(fields.field, cursorLoc);
    Maybe[loc] smallestKeywordContainingCursor = findSmallestContaining(keywords.kw, cursorLoc);

    rel[loc l, CursorKind kind] locsContainingCursor = {
        <l, k>
        | <just(l), k> <- {
                // Uses
                <findSmallestContaining(ws.useDef<0>, cursorLoc), use()>
                // Defs with an identifier equals the name under the cursor
              , <findSmallestContaining((ws.defines<id, defined>)[cursorName], cursorLoc), def()>
                // Type parameters
              , <findSmallestContaining({l | l <- ws.facts, aparameter(cursorName, _) := ws.facts[l]}, cursorLoc), typeParam()>
                // Any kind of field; we'll decide which exactly later
              , <smallestFieldContainingCursor, collectionField()>
              , <smallestFieldContainingCursor, dataField(|unknown:///|)>
              , <smallestFieldContainingCursor, dataKeywordField(|unknown:///|)>
            //   , <smallestFieldContainingCursor, dataCommonKeywordField(|unknown:///|)>
                // Any kind of keyword param; we'll decide which exactly later
              , <smallestKeywordContainingCursor, dataKeywordField(|unknown:///|)>
            //   , <smallestKeywordContainingCursor, dataCommonKeywordField(|unknown:///|)>
              , <smallestKeywordContainingCursor, keywordParam()>
                // Module name declaration, where the cursor location is in the module header
              , <flatMap(rascalLocationOfName(parseModuleWithSpacesCached(cursorLoc.top).top.header), Maybe[loc](loc nameLoc) { return isContainedIn(cursorLoc, nameLoc) ? just(nameLoc) : nothing(); }), moduleName()>
            }
    };

    if (locsContainingCursor == {}) {
        throw unsupportedRename("Renaming \'<cursorName>\' at  <cursorLoc> is not supported.");
    }

    // print("Defines: ");
    // iprintln(ws.definitions);

    // print("Facts: ");
    // iprintln(ws.facts);


    Cursor getDataFieldCursor(AType containerType, loc container) {
        if (Define dt := rascalGetADTDefinition(ws, containerType, container)
          , adtType := dt.defInfo.atype) {
            if (rascalAdtHasCommonKeywordField(cursorName, dt)) {
                // Case 4 or 5 (or 0): common keyword field
                return cursor(dataCommonKeywordField(dt.defined), c, cursorName);
            } else if (Define d: <_, _, _, constructorId(), _, defType(acons(adtType, _, _))> <- ws.defines) {
                if (rascalConsHasKeywordField(cursorName, d)) {
                    // Case 3 (or 0): keyword field
                    return cursor(dataKeywordField(dt.defined), c, cursorName);
                } else if (rascalConsHasField(cursorName, d)) {
                    // Case 2 (or 0): positional field
                    return cursor(dataField(dt.defined), c, cursorName);
                }
            }
        }

        throw "Cannot derive data field information for <containerType> at <container>";
    }

    loc c = min(locsContainingCursor.l);
    Cursor cur = cursor(use(), |unknown:///|, "");
    print("Locs containing cursor: ");
    iprintln(locsContainingCursor);
    switch (locsContainingCursor[c]) {
        case {moduleName(), *_}: {
            cur = cursor(moduleName(), c, cursorName);
        }
        case {keywordParam(), dataKeywordField(_), *_}: {
            if ({loc container} := keywords[c], just(containerType) := getFact(ws, container)) {
                cur = getDataFieldCursor(containerType, container);
            }
        }
        case {collectionField(), dataField(_), dataKeywordField(_), *_}: { //, dataCommonKeywordField(_), *_}: {
            /* Possible cases:
                0. We are on a field use/access (of either a data or collection field, in an expression/assignment/pattern(?))
                1. We are on a collection field
                2. We are on a positional field definition (inside a constructor variant, inside a data def)
                3. We are on a keyword field definition (inside a constructor variant)
                4. We are on a common keyword field definition (inside a data def)
                5. We are on a (common) keyword argument (inside a constructor call)
             */

            // Let's figure out what kind of field we are exactly
            if ({loc container} := fields[c], maybeContainerType := getFact(ws, container)) {
                if ((just(containerType) := maybeContainerType && rascalIsCollectionType(containerType))
                 || maybeContainerType == nothing()) {
                    // Case 1 (or 0): collection field
                    cur = cursor(collectionField(), c, cursorName);
                } else if (just(containerType) := maybeContainerType) {
                    cur = getDataFieldCursor(containerType, container);
                }
            }
        }
        case {def(), *_}: {
            // Cursor is at a definition
            cur = cursor(def(), c, cursorName);
        }
        case {use(), *_}: {
            set[loc] defs = getDefs(ws, c);
            set[Define] defines = {ws.definitions[d] | d <- defs, ws.definitions[d]?};

            if (d <- defs, just(amodule(_)) := getFact(ws, d)) {
                // Cursor is at an import
                cur = cursor(moduleName(), c, cursorName);
            } else if (u <- ws.useDef<0>
                     , isContainedIn(cursorLoc, u)
                     , u.end > cursorLoc.end
                     // If the cursor is on a variable, we expect a module variable (`moduleVariable()`); not a local (`variableId()`)
                     , {variableId()} !:= (ws.defines<defined, idRole>)[getDefs(ws, u)]
                ) {
                // Cursor is at a qualified name
                cur = cursor(moduleName(), c, cursorName);
            // } else if (/Tree t := parseModuleWithSpacesCached(cursorLoc.top)
            //          , just(<lhs, {field, _*}>) := getFieldLoc(cursorName, t)
            //          , just(acons(adtType, _, _)) := getFact(ws, lhs)
            //          , Define dataDef: <_, _, _, dataId(), _, defType(AType adtType)> <- ws.defines
            //          , Define kwDef: <_, cursorName, _, keywordFormalId(), _, _> <- ws.defines
            //          , isStrictlyContainedIn(kwDef.defined, dataDef.defined)) {
            //     // Cursor is at a field use
            //     cur = cursor(dataField(), kwDef.defined, cursorName);
            } else if (defines != {}) {
                // The cursor is at a use with corresponding definitions.
                cur = cursor(use(), c, cursorName);
            } else if (just(at) := getFact(ws, c)
                     , aparameter(cursorName, _) := at) {
                // The cursor is at a type parameter
                cur = cursor(typeParam(), c, cursorName);
            }
        }
        case {k}: {
            cur = cursor(k, c, cursorName);
        }
    }

    if (cur.l.scheme == "unknown") throw unsupportedRename("Could not retrieve information for \'<cursorName>\' at <cursorLoc>.");

    println("Cursor: <cur>");

    return <cur, ws>;
}

private set[Name] rascalNameToEquivalentNames(str name) = {
    [Name] name,
    startsWith(name, "\\") ? [Name] name : [Name] "\\<name>"
};

private bool rascalContainsName(loc l, str name) {
    m = parseModuleWithSpacesCached(l);
    for (n <- rascalNameToEquivalentNames(name)) {
        if (/n := m) return true;
    }
    return false;
}

@synopsis{
    Rename the Rascal symbol under the cursor. Renames all related (overloaded) definitions and uses of those definitions.
    Renaming is not supported for some symbols.
}
@description {
    Rename the Rascal symbol under the cursor, across all currently open projects in the workspace.
    The following symbols are supported.
    - Variables
    - Pattern variables
    - Parameters (positional, keyword)
    - Functions
    - Annotations (on values)
    - Collection fields (tuple, relations)
    - Modules
    - Aliases
    - Data types
    - Type parameters

    The following symbols are currently unsupported.
    - Annotations (on functions)
    - Data constructors
    - Data constructor fields (fields, keyword fields, common keyword fields)

    *Name resolution*
    A renaming triggers the typechecker on the currently open file to determine the scope of the renaming.
    If the renaming is not function-local, it might trigger the type checker on all files in the workspace to find rename candidates.
    A renaming requires all files in which the name is used to be without errors.

    *Overloading*
    Considers recognizes overloaded definitions and renames those as well.

    Functions will be considered overloaded when they have the same name, even when the arity or type signature differ.
    This means that the following functions defitions will be renamed in unison:
    ```
    list[&T] concat(list[&T] _, list[&T] _) = _;
    set[&T] concat(set[&T] _, set[&T] _) = _;
    set[&T] concat(set[&T] _, set[&T] _, set[&T] _) = _;
    ```

    *Validity checking*
    Once all rename candidates have been resolved, validity of the renaming will be checked. A rename is valid iff
    1. It does not introduce errors.
    2. It does not change the semantics of the application.
    3. It does not change definitions outside of the current workspace.
}
list[DocumentEdit] rascalRenameSymbol(Tree cursorT, set[loc] workspaceFolders, str newName, PathConfig(loc) getPathConfig)
    { // }= job("renaming <cursorT> to <newName>", list[DocumentEdit](void(str, int) step) {
    loc cursorLoc = cursorT.src;
    str cursorName = "<cursorT>";

    // step("collecting workspace information", 1);
    WorkspaceInfo ws = workspaceInfo(
        // Preload
        ProjectFiles() {
            return { <
                max([f | f <- workspaceFolders, isPrefixOf(f, cursorLoc)]),
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
                // If we do not find any occurrences of the name under the cursor in a module,
                // we are not interested in it at all, and will skip loading its TPL.
                , rascalContainsName(file, cursorName)
            };
        },
        // Load TModel for loc
        set[TModel](ProjectFiles projectFiles) {
            set[TModel] tmodels = {};

            for (projectFolder <- projectFiles.projectFolder, \files := projectFiles[projectFolder]) {
                PathConfig pcfg = getPathConfig(projectFolder);
                RascalCompilerConfig ccfg = rascalCompilerConfig(pcfg)[forceCompilationTopModule = true]
                                                                      [verbose = false]
                                                                      [logPathConfig = false];
                for (file <- \files) {
                    ms = rascalTModelForLocs([file], ccfg, dummy_compile1);
                    tmodels += {convertTModel2PhysicalLocs(tm) | m <- ms.tmodels, tm := ms.tmodels[m]};
                }
            }
            return tmodels;
        }
    );

    // step("analyzing name at cursor", 1);
    <cur, ws> = rascalGetCursor(ws, cursorT);

    // step("loading required type information", 1);
    if (!rascalIsFunctionLocal(ws, cur)) {
        // println("Renaming not module-local; loading more information from workspace.");
        ws = loadWorkspace(ws);
    // } else {
    //     println("Renaming guaranteed to be module-local.");
    }

    // print("Defines: ");
    // iprintln({<d.id, d> | d <- ws.defines}["Foo"]);

    // print("Scopes: ");
    // iprintln(ws.scopes);

    // step("collecting uses of \'<cursorName>\'", 1);
    <defs, uses, getRenames> = rascalGetDefsUses(ws, cur, rascalMayOverloadSameName, getPathConfig);

    rel[loc file, loc defines] defsPerFile = {<d.top, d> | d <- defs};
    rel[loc file, loc uses] usesPerFile = {<u.top, u> | u <- uses};

    set[loc] \files = defsPerFile.file + usesPerFile.file;

    // step("checking rename validity", 1);
    map[loc, tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits]] moduleResults =
        (file: <reasons, edits> | file <- \files, <reasons, edits> := computeTextEdits(ws, file, defsPerFile[file], usesPerFile[file], newName));

    if (reasons := union({moduleResults[file].reasons | file <- moduleResults}), reasons != {}) {
        list[str] reasonDescs = toList({describe(r) | r <- reasons});
        throw illegalRename("Rename is not valid, because:\n - <intercalate("\n - ", reasonDescs)>", reasons);
    }

    list[DocumentEdit] changes = [changed(file, moduleResults[file].edits) | file <- moduleResults];
    list[DocumentEdit] renames = [renamed(from, to) | <from, to> <- getRenames(newName)];

    return changes + renames;
}//, totalWork = 5);

//// WORKAROUNDS

// Workaround to be able to pattern match on the emulated `src` field
data Tree (loc src = |unknown:///|(0,0,<0,0>,<0,0>));
