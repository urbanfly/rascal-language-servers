/*
 * Copyright (c) 2018-2023, NWO-I CWI and Swat.engineering
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
package org.rascalmpl.vscode.lsp;

import java.util.concurrent.CompletableFuture;
import java.util.function.BiFunction;

import org.checkerframework.checker.nullness.qual.MonotonicNonNull;
import org.rascalmpl.values.parsetrees.ITree;
import org.rascalmpl.vscode.lsp.util.Versioned;

import io.usethesource.vallang.ISourceLocation;

/**
 * TextDocumentState encapsulates the current contents of every open file editor,
 * and the corresponding latest parse tree that belongs to it.
 * It is parametrized by the parser that must be used to map the string
 * contents to a tree. All other TextDocumentServices depend on this information.
 *
 * Objects of this class are used by the implementations of RascalTextDocumentService
 * and ParametricTextDocumentService.
 */
public class TextDocumentState {
    private final BiFunction<ISourceLocation, String, CompletableFuture<ITree>> parser;

    private final ISourceLocation file;
    private volatile int currentVersion;
    private volatile String currentContent;
    @SuppressWarnings("java:S3077") // we are use volatile correctly
    private volatile @MonotonicNonNull Versioned<ITree> lastFullTree;
    @SuppressWarnings("java:S3077") // we are use volatile correctly
    private volatile CompletableFuture<Versioned<ITree>> currentTree;

    public TextDocumentState(BiFunction<ISourceLocation, String, CompletableFuture<ITree>> parser, ISourceLocation file, int version, String content) {
        this.parser = parser;
        this.file = file;
        this.currentVersion = version;
        this.currentContent = content;
        currentTree = newContent(version, content);
    }

    /**
     * The current call of this method guarantees that, until the next call,
     * each intermediate call of `getCurrentTreeAsync` returns (a future for) a
     * *correct* versioned tree. This means that:
     *   - the version of the tree is argument `version`;
     *   - the tree is produced by parsing argument `content`.
     *
     * Thus, callers of `getCurrentTreeAsync` are guaranteed to obtain a
     * consistent <version, tree> pair.
     *
     * Note: In contrast, separate calls to `getCurrentVersion` and
     * `getCurrentContent` are not synchronized and do no provide similar
     * guarantees. Use these methods only if *either* the current version *or*
     * the current content is needed (but not both).
     */
    public CompletableFuture<Versioned<ITree>> update(int version, String content) {
        currentVersion = version;
        currentContent = content;
        currentTree = newContent(version, content);
        return currentTree;
    }

    @SuppressWarnings("java:S1181") // we want to catch all Java exceptions from the parser
    private CompletableFuture<Versioned<ITree>> newContent(int version, String content) {
        return parser.apply(file, content)
            .thenApply(t -> new Versioned<ITree>(version, t))
            .whenComplete((r, t) -> {
                if (r != null) {
                    lastFullTree = r;
                }
            });
    }

    public CompletableFuture<Versioned<ITree>> getCurrentTreeAsync() {
        return currentTree;
    }

    public @MonotonicNonNull Versioned<ITree> getMostRecentTree() {
        return lastFullTree;
    }

    public ISourceLocation getLocation() {
        return file;
    }

    public int getCurrentVersion() {
        return currentVersion;
    }

    public String getCurrentContent() {
        return currentContent;
    }
}
