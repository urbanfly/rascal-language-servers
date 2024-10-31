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

extend lang::rascal::lsp::refactor::Exception;
import lang::rascal::lsp::refactor::Util;
import lang::rascal::lsp::refactor::WorkspaceInfo;

import lang::rascal::lsp::refactor::TextEdits;

import util::FileSystem;
import util::Maybe;
import util::Monitor;
import util::Reflective;

alias Edits = tuple[list[DocumentEdit], map[ChangeAnnotationId, ChangeAnnotation]];

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

set[IllegalRenameReason] rascalCheckLegalName(str name, set[IdRole] defRoles) {
    set[IllegalRenameReason] tryParseAs(type[&T <: Tree] begin, str idDescription) {
        try {
            parse(begin, rascalEscapeName(name));
            return {};
        } catch ParseError(_): {
            return {invalidName(name, idDescription)};
        }
    }

    bool isSyntaxRole = any(role <- defRoles, role in syntaxRoles);
    bool isField = any(role <- defRoles, role is fieldId);
    bool isConstructor = any(role <- defRoles, role is constructorId);

    set[IllegalRenameReason] reasons = {};
    if (isSyntaxRole) {
        reasons += tryParseAs(#Nonterminal, "non-terminal name");
    }
    if (isField) {
        reasons += tryParseAs(#NonterminalLabel, "constructor field name");
    }
    if (isConstructor) {
        reasons += tryParseAs(#NonterminalLabel, "constructor name");
    }
    if (!(isSyntaxRole || isField || isConstructor)) {
        reasons += tryParseAs(#Name, "identifier");
    }

    return reasons;
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
        | Define _: <curFieldScope, _, _, fieldId(), cD, _> <- definitionsRel(ws)[currentDefs]
          // The scope of a field def is the surrounding data def
        , loc dataDef <- rascalGetOverloadedDefs(ws, {curFieldScope}, rascalMayOverloadSameName)
        , loc nD <- (newDefs<idRole, defined>)[fieldId()] & (ws.defines<idRole, scope, defined>)[fieldId(), dataDef]
    };

    rel[loc old, loc new] doubleTypeParamDeclarations = {<cD, nD>
        | loc cD <- currentDefs
        , ws.facts[cD]?
        , cT: aparameter(_, _) := ws.facts[cD]
        , Define fD: <_, _, _, _, _, defType(afunc(_, funcParams:/cT, _))> <- ws.defines
        , isContainedIn(cD, fD.defined)
        , <loc nD, nT: aparameter(newName, _)> <- toRel(ws.facts)
        , isContainedIn(nD, fD.defined)
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
        rascalCheckLegalName(newName, definitionsRel(ws)[currentDefs].idRole)
      + rascalCheckDefinitionsOutsideWorkspace(ws, currentDefs)
      + rascalCheckCausesDoubleDeclarations(ws, currentDefs, newNameDefs, newName)
      + rascalCheckCausesCaptures(ws, m, currentDefs, currentUses, newNameDefs)
    ;
}

private str rascalEscapeName(str name) = name in getRascalReservedIdentifiers() ? "\\<name>" : name;

// Find the smallest trees of defined non-terminal type with a source location in `useDefs`
private map[loc, loc] rascalFindNamesInUseDefs(start[Module] m, set[loc] useDefs) {
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

    return useDefNameAt;
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
Maybe[loc] rascalLocationOfName(SyntaxDefinition sd) = rascalLocationOfName(sd.defined);
Maybe[loc] rascalLocationOfName(Sym sym) = just(sym.nonterminal.src);
Maybe[loc] rascalLocationOfName(Nonterminal nt) = just(nt.src);
Maybe[loc] rascalLocationOfName(NonterminalLabel l) = just(l.src);
default Maybe[loc] rascalLocationOfName(Tree t) = nothing();

private tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits] computeTextEdits(WorkspaceInfo ws, start[Module] m, set[RenameLocation] defs, set[RenameLocation] uses, str name) {
    if (reasons := rascalCollectIllegalRenames(ws, m, toLocs(defs), toLocs(uses), name), reasons != {}) {
        return <reasons, []>;
    }

    replaceName = rascalEscapeName(name);

    set[RenameLocation] renames = defs + uses;
    set[loc] renameLocs = toLocs(renames);
    map[loc, loc] namesAt = rascalFindNamesInUseDefs(m, renameLocs);
    rel[loc, Maybe[ChangeAnnotationId]] annosAt = {<r.l, r.annotation> | r <- renames};

    return <{}, [{just(annotation), *_} := annosAt[l]
                 ? replace(namesAt[l], replaceName, annotation)
                 : replace(namesAt[l], replaceName)
                 | l <- renameLocs]>;
}

private tuple[set[IllegalRenameReason] reasons, list[TextEdit] edits] computeTextEdits(WorkspaceInfo ws, loc moduleLoc, set[RenameLocation] defs, set[RenameLocation] uses, str name) =
    computeTextEdits(ws, parseModuleWithSpacesCached(moduleLoc), defs, uses, name);

private bool rascalIsFunctionLocalDefs(WorkspaceInfo ws, set[loc] defs) {
    for (d <- defs) {
        if (Define fun: <_, _, _, _, _, defType(afunc(_, _, _))> <- ws.defines
          , isContainedIn(ws.definitions[d].scope, fun.defined)) {
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

Maybe[AType] rascalAdtCommonKeywordFieldType(WorkspaceInfo ws, str fieldName, Define _:<_, _, _, _, _, DefInfo defInfo>) {
    if (defInfo.commonKeywordFields?
      , kwf:(KeywordFormal) `<Type _> <Name kwName> = <Expression _>` <- defInfo.commonKeywordFields
      , "<kwName>" == fieldName) {
        if (ft:just(_) := getFact(ws, kwf.src)) return ft;
        throw "Unknown field type for <kwf.src>";
    }
    return nothing();
}

Maybe[AType] rascalConsKeywordFieldType(str fieldName, Define _:<_, _, _, constructorId(), _, defType(acons(_, _, kwFields))>) {
    if (kwField(fieldType, fieldName, _) <- kwFields) return just(fieldType);
    return nothing();
}

Maybe[AType] rascalConsFieldType(str fieldName, Define _:<_, _, _, constructorId(), _, defType(acons(_, fields, _))>) {
    if (field <- fields, field.alabel == fieldName) return just(field);
    return nothing();
}

private CursorKind rascalGetDataFieldCursorKind(WorkspaceInfo ws, loc container, loc cursorLoc, str cursorName) {
    for (Define dt <- rascalGetADTDefinitions(ws, container)
        , AType adtType := dt.defInfo.atype) {
        if (just(fieldType) := rascalAdtCommonKeywordFieldType(ws, cursorName, dt)) {
            // Case 4 or 5 (or 0): common keyword field
            return dataCommonKeywordField(dt.defined, fieldType);
        }

        for (Define d: <_, _, _, constructorId(), _, defType(acons(adtType, _, _))> <- rascalReachableDefs(ws, {dt.defined})) {
            if (just(fieldType) := rascalConsKeywordFieldType(cursorName, d)) {
                // Case 3 (or 0): keyword field
                return dataKeywordField(dt.defined, fieldType);
            } else if (just(fieldType) := rascalConsFieldType(cursorName, d)) {
                // Case 2 (or 0): positional field
                return dataField(dt.defined, fieldType);
            }
        }

        if (Define d: <_, cursorName, _, fieldId(), _, defType(adtType)> <- rascalReachableDefs(ws, {dt.defined})) {
            return dataField(dt.defined, d.defInfo.atype);
        }
    }

    set[loc] fromDefs = cursorLoc in ws.useDef<1> ? {cursorLoc} : getDefs(ws, cursorLoc);
    throw illegalRename("Cannot rename \'<cursorName>\'; it is not defined in this workspace", {definitionsOutsideWorkspace(fromDefs)});
}

private CursorKind rascalGetCursorKind(WorkspaceInfo ws, loc cursorLoc, str cursorName, rel[loc l, CursorKind kind] locsContainingCursor, rel[loc field, loc container] fields, rel[loc kw, loc container] keywords) {
    loc c = min(locsContainingCursor.l);
    switch (locsContainingCursor[c]) {
        case {moduleName(), *_}: {
            return moduleName();
        }
        case {keywordParam(), dataKeywordField(_, _), *_}: {
            if ({loc container} := keywords[c]) {
                return rascalGetDataFieldCursorKind(ws, container, cursorLoc, cursorName);
            }
        }
        case {collectionField(), dataField(_, _), dataKeywordField(_, _), dataCommonKeywordField(_, _), *_}: {
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
                if (maybeContainerType == nothing() || rascalIsCollectionType(maybeContainerType.val)) {
                    // Case 1 (or 0): collection field
                    return collectionField();
                }
                return rascalGetDataFieldCursorKind(ws, container, cursorLoc, cursorName);
            }
        }
        case {def(), *_}: {
            // Cursor is at a definition
            Define d = ws.definitions[c];
            if (d.idRole is fieldId
              , Define adt: <_, _, _, dataId(), _, _> <- ws.defines
              , isStrictlyContainedIn(c, adt.defined)) {
                return rascalGetDataFieldCursorKind(ws, adt.defined, cursorLoc, cursorName);
            }
            return def();
        }
        case {use(), *_}: {
            set[loc] defs = getDefs(ws, c);
            set[Define] defines = {ws.definitions[d] | d <- defs, ws.definitions[d]?};

            if (d <- defs, just(amodule(_)) := getFact(ws, d)) {
                // Cursor is at an import
                return moduleName();
            } else if (u <- ws.useDef<0>
                     , isContainedIn(cursorLoc, u)
                     , u.end > cursorLoc.end
                     // If the cursor is on a variable, we expect a module variable (`moduleVariable()`); not a local (`variableId()`)
                     , {variableId()} !:= (ws.defines<defined, idRole>)[getDefs(ws, u)]
                ) {
                // Cursor is at a qualified name
                return moduleName();
            } else if (defines != {}) {
                // The cursor is at a use with corresponding definitions.
                return use();
            } else if (just(at) := getFact(ws, c)
                     , aparameter(cursorName, _) := at) {
                // The cursor is at a type parameter
                return typeParam();
            }
        }
        case {k}: {
            return k;
        }
    }

    throw unsupportedRename("Could not retrieve information for \'<cursorName>\' at <cursorLoc>.");
}

private Cursor rascalGetCursor(WorkspaceInfo ws, Tree cursorT) {
    loc cursorLoc = cursorT.src;
    str cursorName = "<cursorT>";

    rel[loc field, loc container] fields = {<fieldLoc, containerLoc>
        | /Tree t := parseModuleWithSpacesCached(cursorLoc.top)
        , just(<containerLoc, fieldLocs, _>) := rascalGetFieldLocs(cursorName, t)
        , loc fieldLoc <- fieldLocs
    };

    rel[loc kw, loc container] keywords = {<kwLoc, containerLoc>
        | /Tree t := parseModuleWithSpacesCached(cursorLoc.top)
        , just(<containerLoc, kwLocs, _>) := rascalGetKeywordLocs(cursorName, t)
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
              , <smallestFieldContainingCursor, dataField(|unknown:///|, avoid())>
              , <smallestFieldContainingCursor, dataKeywordField(|unknown:///|, avoid())>
              , <smallestFieldContainingCursor, dataCommonKeywordField(|unknown:///|, avoid())>
                // Any kind of keyword param; we'll decide which exactly later
              , <smallestKeywordContainingCursor, dataKeywordField(|unknown:///|, avoid())>
              , <smallestKeywordContainingCursor, dataCommonKeywordField(|unknown:///|, avoid())>
              , <smallestKeywordContainingCursor, keywordParam()>
                // Module name declaration, where the cursor location is in the module header
              , <flatMap(rascalLocationOfName(parseModuleWithSpacesCached(cursorLoc.top).top.header), Maybe[loc](loc nameLoc) { return isContainedIn(cursorLoc, nameLoc) ? just(nameLoc) : nothing(); }), moduleName()>
                // Nonterminal constructor names in exception productions
              , <findSmallestContaining({l | l <- ws.facts, at := ws.facts[l], (at is conditional || aprod(prod(_, /conditional(_, _))) := at), /\a-except(cursorName) := at}, cursorLoc), exceptConstructor()>
            }
    };

    if (locsContainingCursor == {}) {
        throw unsupportedRename("Renaming \'<cursorName>\' at  <cursorLoc> is not supported.");
    }

    CursorKind kind = rascalGetCursorKind(ws, cursorLoc, cursorName, locsContainingCursor, fields, keywords);
    return cursor(kind, min(locsContainingCursor.l), cursorName);
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
    - Data constructors
    - Data constructor fields (fields, keyword fields, common keyword fields)

    The following symbols are currently unsupported.
    - Annotations (on functions)

    *Name resolution*
    A renaming triggers the typechecker on the currently open file to determine the scope of the renaming.
    If the renaming is not function-local, it might trigger the type checker on all files in the workspace to find rename candidates.
    A renaming requires all files in which the name is used to be without errors.

    *Overloading*
    Considers recognizes overloaded definitions and renames those as well.

    Functions are considered overloaded when they have the same name, even when the arity or type signature differ.
    This means that the following functions defitions will be renamed in unison:
    ```
    list[&T] concat(list[&T] _, list[&T] _) = _;
    set[&T] concat(set[&T] _, set[&T] _) = _;
    set[&T] concat(set[&T] _, set[&T] _, set[&T] _) = _;
    ```

    ADT and grammar definitions are considered overloaded when they have the same name and type, and
    there is a common use from which they are reachable.
    As an example, modules `A` and `B` have a definition for ADT `D`:
    ```
    module A
    data D = a();
    ```
    ```
    module B
    data D = b();
    ```
    With no other modules in the workspace, renaming `D` in one of those modules, will not rename `D` in
    the other module, as they are not considered an overloaded definition. However, if a third module `C`
    exists, that imports both and uses the definition, the definitions will be considered overloaded, and
    renaming `D` from either module `A`, `B` or `C` will result in renaming all occurrences.
    ```
    module C
    import A;
    import B;
    D f() = a();
    ```

    *Validity checking*
    Once all rename candidates have been resolved, validity of the renaming will be checked. A rename is valid iff
    1. It does not introduce errors.
    2. It does not change the semantics of the application.
    3. It does not change definitions outside of the current workspace.
}
Edits rascalRenameSymbol(Tree cursorT, set[loc] workspaceFolders, str newName, PathConfig(loc) getPathConfig)
    = job("renaming <cursorT> to <newName>", Edits(void(str, int) step) {
    loc cursorLoc = cursorT.src;
    str cursorName = "<cursorT>";

    step("collecting workspace information", 1);
    WorkspaceInfo ws = workspaceInfo(
        // Get path config
        getPathConfig,
        // Preload
        ProjectFiles() {
            return { <
                max([f | f <- workspaceFolders, isPrefixOf(f, cursorLoc)]),
                cursorLoc.top,
                true
            > };
        },
        // Full load
        ProjectFiles() {
            return {
                // If we do not find any occurrences of the name under the cursor in a module,
                // we are not interested in loading the model, but we still want to inform the
                // renaming framework about the existence of the file.
                <folder, file, rascalContainsName(file, cursorName)>
                | folder <- workspaceFolders
                , PathConfig pcfg := getPathConfig(folder)
                , srcFolder <- pcfg.srcs
                , file <- find(srcFolder, "rsc")
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
                for (<file, true> <- \files) {
                    ms = rascalTModelForLocs([file], ccfg, dummy_compile1);
                    tmodels += {convertTModel2PhysicalLocs(tm) | m <- ms.tmodels, tm := ms.tmodels[m]};
                }
            }
            return tmodels;
        }
    );

    step("preloading minimal workspace information", 1);
    ws = preLoad(ws);

    step("analyzing name at cursor", 1);
    cur = rascalGetCursor(ws, cursorT);

    step("loading required type information", 1);
    if (!rascalIsFunctionLocal(ws, cur)) {
        ws = loadWorkspace(ws);
    }

    step("collecting uses of \'<cursorName>\'", 1);

    map[ChangeAnnotationId, ChangeAnnotation] changeAnnotations = ();
    ChangeAnnotationRegister registerChangeAnnotation = ChangeAnnotationId(str label, str description, bool needsConfirmation) {
        ChangeAnnotationId makeKey(str label, int suffix) = "<label>_<suffix>";

        int suffix = 1;
        while (makeKey(label, suffix) in changeAnnotations) {
            suffix += 1;
        }

        ChangeAnnotationId id = makeKey(label, suffix);
        changeAnnotations[id] = changeAnnotation(label, description, needsConfirmation);

        return id;
    };

    <defs, uses, getRenames> = rascalGetDefsUses(ws, cur, rascalMayOverloadSameName, registerChangeAnnotation);

    rel[loc file, RenameLocation defines] defsPerFile = {<d.l.top, d> | d <- defs};
    rel[loc file, RenameLocation uses] usesPerFile = {<u.l.top, u> | u <- uses};

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

    return <changes + renames, changeAnnotations>;
}, totalWork = 6);

//// WORKAROUNDS

// Workaround to be able to pattern match on the emulated `src` field
data Tree (loc src = |unknown:///|(0,0,<0,0>,<0,0>));
