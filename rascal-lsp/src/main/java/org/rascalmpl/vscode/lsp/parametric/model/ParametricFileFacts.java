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
package org.rascalmpl.vscode.lsp.parametric.model;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;
import java.util.function.Supplier;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.checkerframework.checker.nullness.qual.MonotonicNonNull;
import org.eclipse.lsp4j.Diagnostic;
import org.eclipse.lsp4j.PublishDiagnosticsParams;
import org.eclipse.lsp4j.services.LanguageClient;
import org.rascalmpl.values.parsetrees.ITree;
import org.rascalmpl.vscode.lsp.TextDocumentState;
import org.rascalmpl.vscode.lsp.parametric.ILanguageContributions;
import org.rascalmpl.vscode.lsp.util.Versioned;
import org.rascalmpl.vscode.lsp.util.locations.ColumnMaps;

import io.usethesource.vallang.ISourceLocation;

public class ParametricFileFacts {
    private static final Logger logger = LogManager.getLogger(ParametricFileFacts.class);
    private final Executor exec;
    private volatile @MonotonicNonNull LanguageClient client;
    private final Map<ISourceLocation, FileFact> files = new ConcurrentHashMap<>();
    private final ILanguageContributions contrib;
    private final Function<ISourceLocation, TextDocumentState> lookupState;
    private final ColumnMaps columns;

    public ParametricFileFacts(ILanguageContributions contrib, Function<ISourceLocation, TextDocumentState> lookupState,
        ColumnMaps columns, Executor exec) {
        this.contrib = contrib;
        this.lookupState = lookupState;
        this.columns = columns;
        this.exec = exec;
    }

    public void setClient(LanguageClient client) {
        this.client = client;
    }

    public void reportParseErrors(ISourceLocation file, Versioned<ITree> tree, List<Diagnostic> msgs) {
        getFile(file).reportParseErrors(tree, msgs);
    }

    private FileFact getFile(ISourceLocation l) {
        return files.computeIfAbsent(l, FileFact::new);
    }

    public void reloadContributions() {
        files.values().forEach(FileFact::reloadContributions);
    }

    public ParametricSummaryBridge getSummaryAnalyzer(ISourceLocation file) {
        return getFile(file).getSummaryAnalyzer();
    }

    public ParametricSummaryBridge getSummaryBuilder(ISourceLocation file) {
        return getFile(file).getSummaryBuilder();
    }

    public void invalidateAnalyzer(ISourceLocation file) {
        var current = files.get(file);
        if (current != null) {
            current.invalidateAnalyzer(false);
        }
    }

    public void invalidateBuilder(ISourceLocation file) {
        var current = files.get(file);
        if (current != null) {
            current.invalidateBuilder(false);
        }
    }

    public void calculateAnalyzer(ISourceLocation file, int version, Duration delay) {
        getFile(file).calculateAnalyzer(version, delay);
    }

    public void calculateBuilder(ISourceLocation file, int version, Duration delay) {
        getFile(file).calculateBuilder(version, delay);
    }

    public void close(ISourceLocation loc) {
        var present = files.get(loc);
        if (present != null) {
            present.invalidateAnalyzer(true);
            present.invalidateBuilder(true);

            var messagesAnalyzer = present.summaryAnalyzer.getMessages();
            var messagesBuilder = present.summaryBuilder.getMessages();
            messagesAnalyzer.thenAcceptBothAsync(messagesBuilder, (m1, m2) -> {
                if (m1.isEmpty() && m2.isEmpty()) {
                    // only if there are no messages for this class, can we remove it
                    // else vscode comes back and we've dropped the messages in our internal data
                    files.remove(loc);
                }
            });
        }
    }

    /**
     * This class keeps together diagnostics messages and the versioned AST for
     * which the diagnostics were computed. This is needed to ensure that
     * builder diagnostics are calculated for the same AST as
     * supposedly-corresponding analyzer diagnostics.
     */
    private static class VersionedDiagnostics {
        public final Versioned<ITree> tree;
        public final List<Diagnostic> messages;

        public VersionedDiagnostics(Versioned<ITree> tree, List<Diagnostic> messages) {
            this.tree = tree;
            this.messages = messages;
        }

        public static boolean setIfNewer(AtomicReference<VersionedDiagnostics> box, VersionedDiagnostics maybeNewer) {
            var success = false;
            var retry = true;
            while (retry) {
                var old = box.get();
                if (old == null || old.tree.version < maybeNewer.tree.version) {
                    success = box.compareAndSet(old, maybeNewer);
                    retry = !success;
                } else {
                    retry = false;
                }
            }
            return success;
        }

        public static List<Diagnostic> union(VersionedDiagnostics... list) {
            var messages = new ArrayList<Diagnostic>();
            for (var versionedDiagnostics : list) {
                if (versionedDiagnostics != null) {
                    messages.addAll(versionedDiagnostics.messages);
                }
            }
            return messages;
        }
    }

    private class FileFact {
        private final ISourceLocation file;

        // To replace old diagnostics when new diagnostics become available in a
        // thread-safe way, we need to atomically: (1) check if the version of
        // the new diagnostics is greater than the version of the old
        // diagnostics; (2) if so, replace old with new. This is why
        // `AtomicReference` and `VersionedDiagnostics` are needed here.
        private final AtomicReference<VersionedDiagnostics> diagnosticsParser = new AtomicReference<>();
        private final AtomicReference<VersionedDiagnostics> diagnosticsAnalyzer = new AtomicReference<>();
        private final AtomicReference<VersionedDiagnostics> diagnosticsBuilder = new AtomicReference<>();

        private final ParametricSummaryBridge summaryAnalyzer;
        private final ParametricSummaryBridge summaryBuilder;

        private final AtomicInteger latestVersionCalculateAnalyzer = new AtomicInteger();
        private final AtomicInteger latestVersionCalculateBuilder = new AtomicInteger();

        @SuppressWarnings("java:S3077")
        private volatile @MonotonicNonNull CompletableFuture<Optional<VersionedDiagnostics>> calculateAnalyzerLatestResult;

        public FileFact(ISourceLocation file) {
            this.file = file;
            this.summaryAnalyzer = new ParametricSummaryBridge(exec, file, columns, contrib, lookupState, contrib::analyze);
            this.summaryBuilder = new ParametricSummaryBridge(exec, file, columns, contrib, lookupState, contrib::build);
        }

        public void reloadContributions() {
            summaryAnalyzer.reloadContributions();
            summaryBuilder.reloadContributions();
        }

        private VersionedDiagnostics reportDiagnostics(AtomicReference<VersionedDiagnostics> box,
                Versioned<ITree> tree, List<Diagnostic> messages) {

            var newer = new VersionedDiagnostics(tree, messages);
            if (VersionedDiagnostics.setIfNewer(box, newer)) {
                sendDiagnostics();
            }
            return newer;
        }

        private void invalidate(ParametricSummaryBridge summary, boolean isClosing) {
            summary.invalidate(isClosing);
        }

        public void invalidateAnalyzer(boolean isClosing) {
            invalidate(summaryAnalyzer, isClosing);
        }

        public void invalidateBuilder(boolean isClosing) {
            invalidate(summaryBuilder, isClosing);
        }

        /**
         * @param version the version of the file for which summary calculation
         * is currently requested
         * @param latestVersion the last version of the file for which summary
         * calculation was previously requested
         * @param delay the duration after which the current request for summary
         * calculation will be granted, unless another request is made in the
         * meantime (in which case the current request is abandoned)
         * @param calculation the actual summary calculation
         * @return a future that provides optional diagnostics that result from
         * the summary calculation
         */
        private CompletableFuture<Optional<VersionedDiagnostics>> calculate(
                int version, AtomicInteger latestVersion, Duration delay,
                Supplier<CompletableFuture<Optional<VersionedDiagnostics>>> calculation) {

            latestVersion.set(version);
            var delayed = CompletableFuture.delayedExecutor(delay.toMillis(), TimeUnit.MILLISECONDS, exec);
            return CompletableFuture.supplyAsync(() -> {
                // If no new call to `calculate` has been made after `delay` has
                // passed (i.e., `lastVersion` hasn't changed in the meantime),
                // then run the calculation. Else, abandon this calculation.
                if (latestVersion.get() == version) {
                    return calculation.get();
                } else {
                    return CompletableFuture.completedFuture(Optional.<VersionedDiagnostics>empty());
                }
            }, delayed).thenCompose(Function.identity());
        }

        public void calculateAnalyzer(int version, Duration delay) {
            calculateAnalyzerLatestResult = calculate(version, latestVersionCalculateAnalyzer, delay, () -> {
                var analysis = summaryAnalyzer.calculateSummary();
                var analysisTree = analysis.input;
                var analysisMessages = analysis.output.get().thenApply(Supplier::get);
                return analysisTree.thenCombine(analysisMessages, (tree, messages) -> {
                    if (analysis.calculation.isInterrupted()) {
                        return Optional.<VersionedDiagnostics>empty();
                    } else {
                        return Optional.of(reportDiagnostics(diagnosticsAnalyzer, tree, messages));
                    }
                });
            });
        }

        /**
         * The main challenge when running the builder is that it might produce
         * a subset of the same diagnostics as the analyzer. Thus, to avoid
         * showing the same diagnostics twice, a diff needs to be computed of
         * the latest analyzer diagnostics and the current builder diagnostics.
         * To do this in a reliable way, each builder calculation awaits the
         * completion of the latest analyzer calculation, such that:
         *   - the builder can use exactly the same AST as the analyzer;
         *   - the builder has access to the diagnostics of the analyzer.
         */
        public void calculateBuilder(int version, Duration delay) {

            // If an analyzer calculation hasn't been scheduled yet (ever), then
            // it needs to be scheduled first.
            if (calculateAnalyzerLatestResult == null) {
                calculateAnalyzer(version, Duration.ZERO);
                calculateBuilder(version, delay);
            }

            // If an analyzer calculation has been scheduled before, then the
            // builder can await its completion.
            else {
                calculateAnalyzerLatestResult.thenAccept(result -> {

                    // If the analyzer calculation wasn't abandoned (due to
                    // debouncing) or interrupted, then diagnostics of the
                    // analyzer are available, so proceed.
                    if (result.isPresent()) {
                        var analysis = result.get();
                        calculate(version, latestVersionCalculateBuilder, delay, () -> {

                            // Use exactly the same AST as in the analyzer
                            // calculation. In this way, a reliable diff of the
                            // latest analyzer diagnostics and the current
                            // builder diagnostics can be computed (by removing
                            // the former from the latter).
                            var build = summaryBuilder.calculateSummary(CompletableFuture.completedFuture(analysis.tree));
                            var buildTree = build.input;
                            var buildMessages = build.output.get().thenApply(Supplier::get);
                            return buildTree.thenCombine(buildMessages, (tree, messages) -> {
                                if (build.calculation.isInterrupted()) {
                                    return Optional.<VersionedDiagnostics>empty();
                                } else {
                                    messages.removeAll(analysis.messages);
                                    return Optional.of(reportDiagnostics(diagnosticsBuilder, tree, messages));
                                }
                            });
                        });
                    }

                    // If the analyzer was abandoned (due to debouncing) or
                    // interrupted, then diagnostics of the analyzer aren't
                    // available, so retry from the start.
                    else {
                        calculateBuilder(version, delay);
                    }
                });
            }
        }

        public ParametricSummaryBridge getSummaryAnalyzer() {
            return summaryAnalyzer;
        }

        public ParametricSummaryBridge getSummaryBuilder() {
            return summaryBuilder;
        }

        public void reportParseErrors(Versioned<ITree> tree, List<Diagnostic> messages) {
            reportDiagnostics(diagnosticsParser, tree, messages);
        }

        private void sendDiagnostics() {
            if (client == null) {
                logger.debug("Cannot send diagnostics since the client hasn't been registered yet");
                return;
            }
            var messages = VersionedDiagnostics.union(diagnosticsParser.get(), diagnosticsAnalyzer.get(), diagnosticsBuilder.get());
            logger.trace("Sending diagnostics for {}. {} messages", file, messages.size());
            client.publishDiagnostics(new PublishDiagnosticsParams(
                file.getURI().toString(),
                messages));
        }
    }
}
