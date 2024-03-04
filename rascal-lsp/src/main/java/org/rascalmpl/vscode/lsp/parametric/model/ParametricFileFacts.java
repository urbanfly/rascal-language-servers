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
import java.util.Collections;
import java.util.List;
import java.util.Map;
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
import org.checkerframework.checker.nullness.qual.Nullable;
import org.eclipse.lsp4j.Diagnostic;
import org.eclipse.lsp4j.PublishDiagnosticsParams;
import org.eclipse.lsp4j.services.LanguageClient;
import org.rascalmpl.values.parsetrees.ITree;
import org.rascalmpl.vscode.lsp.parametric.ILanguageContributions;
import org.rascalmpl.vscode.lsp.parametric.model.ParametricSummary.LookupFn;
import org.rascalmpl.vscode.lsp.util.Lists;
import org.rascalmpl.vscode.lsp.util.Versioned;
import org.rascalmpl.vscode.lsp.util.locations.ColumnMaps;

import io.usethesource.vallang.ISourceLocation;

public class ParametricFileFacts {
    private static final Logger logger = LogManager.getLogger(ParametricFileFacts.class);

    private final Executor exec;
    private final ColumnMaps columns;
    private final ILanguageContributions contrib;

    private final Map<ISourceLocation, FileFact> files = new ConcurrentHashMap<>();

    @SuppressWarnings("java:S3077") // Reads/writes happen sequentially
    private volatile @MonotonicNonNull LanguageClient client;

    @SuppressWarnings("java:S3077") // Reads/writes happen sequentially
    private volatile CompletableFuture<SingleShooterSummaryFactory> singleShotFactory;

    public ParametricFileFacts(Executor exec, ColumnMaps columns, ILanguageContributions contrib) {
        this.exec = exec;
        this.columns = columns;
        this.contrib = contrib;
    }

    public void setClient(LanguageClient client) {
        this.client = client;
    }

    public void reportParseErrors(ISourceLocation file, int version, List<Diagnostic> msgs) {
        getFile(file).reportParseErrors(version, msgs);
    }

    private FileFact getFile(ISourceLocation l) {
        return files.computeIfAbsent(l, FileFact::new);
    }

    public void reloadContributions() {
        files.values().forEach(FileFact::reloadContributions);

        singleShotFactory = contrib.getSingleShotConfig().thenApply(config ->
            new SingleShooterSummaryFactory(config, exec, columns, contrib));
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

    public void calculateAnalyzer(ISourceLocation file, CompletableFuture<Versioned<ITree>> tree, int version, Duration delay) {
        getFile(file).calculateAnalyzer(tree, version, delay);
    }

    public void calculateBuilder(ISourceLocation file, CompletableFuture<Versioned<ITree>> tree) {
        getFile(file).calculateBuilder(tree);
    }

    public <T> CompletableFuture<List<T>> lookupInSummaries(LookupFn<T> fn, ISourceLocation file, Versioned<ITree> tree) {
        return getFile(file).lookupInSummaries(fn, tree);
    }

    public void close(ISourceLocation loc) {
        var present = files.get(loc);
        if (present != null) {
            present.invalidateAnalyzer(true);
            present.invalidateBuilder(true);

            var messagesAnalyzer = ParametricSummary.getMessages(present.latestAnalyzerAnalysis, exec).get();
            var messagesBuilder = ParametricSummary.getMessages(present.latestBuilderBuild, exec).get();
            messagesAnalyzer.thenAcceptBothAsync(messagesBuilder, (m1, m2) -> {
                if (m1.isEmpty() && m2.isEmpty()) {
                    // only if there are no messages for this class, can we remove it
                    // else vscode comes back and we've dropped the messages in our internal data
                    files.remove(loc);
                }
            });
        }
    }

    private class FileFact {
        private final ISourceLocation file;

        // To replace old diagnostics when new diagnostics become available in a
        // thread-safe way, we need to atomically: (1) check if the version of
        // the new diagnostics is greater than the version of the old
        // diagnostics; (2) if so, replace old with new. This is why
        // `AtomicReference` and `Versioned` are needed in the following three
        // fields.
        private final AtomicReference<Versioned<List<Diagnostic>>> parserDiagnostics = Versioned.atomic(-1, Collections.emptyList());
        private final AtomicReference<Versioned<List<Diagnostic>>> analyzerDiagnostics = Versioned.atomic(-1, Collections.emptyList());
        private final AtomicReference<Versioned<List<Diagnostic>>> builderDiagnostics = Versioned.atomic(-1, Collections.emptyList());

        private final ParametricSummaryBridge analyzer;
        private final ParametricSummaryBridge builder;

        private final AtomicInteger latestVersionCalculateAnalyzer = new AtomicInteger();

        @SuppressWarnings("java:S3077") // Reads/writes happen sequentially
        private volatile @MonotonicNonNull CompletableFuture<Versioned<ParametricSummary>> latestAnalyzerAnalysis;
        @SuppressWarnings("java:S3077") // Reads/writes happen sequentially
        private volatile @MonotonicNonNull CompletableFuture<Versioned<ParametricSummary>> latestBuilderBuild;
        @SuppressWarnings("java:S3077") // Reads/writes happen sequentially
        private volatile @MonotonicNonNull CompletableFuture<Versioned<ParametricSummary>> latestBuilderAnalysis;

        public FileFact(ISourceLocation file) {
            this.file = file;
            this.analyzer = new ParametricSummaryBridge(file, exec, columns, contrib::analyze, contrib::getAnalysisConfig);
            this.builder = new ParametricSummaryBridge(file, exec, columns, contrib::build, contrib::getBuildConfig);
        }

        public void reloadContributions() {
            analyzer.reloadContributions();
            builder.reloadContributions();
        }

        private <T> void reportDiagnostics(AtomicReference<Versioned<T>> current, int version, T messages) {
            var maybeNewer = new Versioned<>(version, messages);
            if (Versioned.replaceIfNewer(current, maybeNewer)) {
                sendDiagnostics();
            }
        }

        public void invalidateAnalyzer(boolean isClosing) {
            invalidate(latestAnalyzerAnalysis, isClosing);
        }

        public void invalidateBuilder(boolean isClosing) {
            invalidate(latestBuilderAnalysis, isClosing);
            invalidate(latestBuilderBuild, isClosing);
        }

        private void invalidate(@Nullable CompletableFuture<Versioned<ParametricSummary>> summary, boolean isClosing) {
            if (summary != null && !isClosing) {
                summary
                    .thenApply(Versioned<ParametricSummary>::get)
                    .thenAccept(ParametricSummary::invalidate);
            }
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
         */
        private CompletableFuture<Versioned<ParametricSummary>> debounce(
                int version, AtomicInteger latestVersion, Duration delay,
                Supplier<CompletableFuture<Versioned<ParametricSummary>>> calculation) {

            latestVersion.set(version);
            // Note: No additional logic (`compareAndSet` in a loop etc.) is
            // needed to change `latestVersion`, because:
            //   - LSP guarantees that the client sends change and save
            //     notifications in-order, and that the server receives them
            //     in-order. Thus, the version number of a file monotonically
            //     increases with each notifications to be processed.
            //   - To process notifications, calls of `didChange` and `didSave`
            //     in `ParametricTextDocumentService` run sequentially and
            //     in-order; these are the only methods that (indirectly) call
            //     `calculate`. Thus, parameter `version` (obtained from the
            //     notifications) monotonically increases with each `calculate`
            //     call.

            var delayed = CompletableFuture.delayedExecutor(delay.toMillis(), TimeUnit.MILLISECONDS, exec);
            var summary = CompletableFuture.supplyAsync(() -> {
                // If no new call to `calculate` has been made after `delay` has
                // passed (i.e., `lastVersion` hasn't changed in the meantime),
                // then run the calculation. Else, abandon this calculation.
                if (latestVersion.get() == version) {
                    return calculation.get();
                } else {
                    var nullSummary = new Versioned<>(version, ParametricSummary.NULL);
                    return CompletableFuture.completedFuture(nullSummary);
                }
            }, delayed);

            return summary.thenCompose(Function.identity());
        }

        public void calculateAnalyzer(CompletableFuture<Versioned<ITree>> tree, int version, Duration delay) {
            latestAnalyzerAnalysis = debounce(version, latestVersionCalculateAnalyzer, delay, () -> {
                var summary = analyzer.calculateSummary(tree);
                var messages = ParametricSummary.getMessages(summary, exec);
                messages.thenAcceptIfUninterrupted(ms -> reportDiagnostics(analyzerDiagnostics, version, ms));
                return summary;
            });
        }

        /**
         * The main complication when running the builder is that it might
         * produce a subset of the same diagnostics as the analyzer. Thus, as
         * the latest parser/analyzer/builder diagnostics are always reported
         * together, a diff needs to be computed of the analyzer diagnostics and
         * the builder diagnostics to avoid reporting duplicates produced by
         * both analyzer and builder.
         */
        public void calculateBuilder(CompletableFuture<Versioned<ITree>> tree) {

            // Schedule the analyzer. This is *always* needed, because the
            // latest result of `calculateAnalyzer` may be for a syntax tree
            // with a greater version than parameter `tree` (because
            // `calculateAnalyzer` has debouncing), or it may be interrupted due
            // to later change (which should not affect the builder).
            latestBuilderAnalysis = analyzer.calculateSummary(tree);
            var analyzerMessages = ParametricSummary.getMessages(latestBuilderAnalysis, exec);

            // Schedule the builder and use exactly the same syntax tree as the
            // analyzer. In this way, a reliable diff of the analyzer
            // diagnostics and the builder diagnostics can be computed (by
            // removing the former from the latter).
            latestBuilderBuild = builder.calculateSummary(tree);
            var builderMessages = ParametricSummary.getMessages(latestBuilderBuild, exec);

            // Only if neither the analyzer nor the builder was interrupted,
            // report diagnostics. Otherwise, *no* diagnostics are reported
            // (instead of reporting an empty list of diagnostics).
            analyzerMessages.thenAcceptBothIfUninterrupted(builderMessages, (aMessages, bMessages) -> {
                bMessages.removeAll(aMessages);
                tree.thenAccept(t -> reportDiagnostics(builderDiagnostics, t.version(), bMessages));
            });
        }

        public void reportParseErrors(int version, List<Diagnostic> messages) {
            reportDiagnostics(parserDiagnostics, version, messages);
        }

        private void sendDiagnostics() {
            if (client == null) {
                logger.debug("Cannot send diagnostics since the client hasn't been registered yet");
                return;
            }
            var messages = Lists.union(
                unwrap(parserDiagnostics),
                unwrap(analyzerDiagnostics),
                unwrap(builderDiagnostics));
            logger.trace("Sending diagnostics for {}. {} messages", file, messages.size());
            client.publishDiagnostics(new PublishDiagnosticsParams(
                file.getURI().toString(),
                messages));
        }

        private List<Diagnostic> unwrap(AtomicReference<Versioned<List<Diagnostic>>> wrappedDiagnostics) {
            return wrappedDiagnostics
                .get()  // Unwrap `AtomicReference`
                .get(); // Unwrap `Versioned`
        }

        private <T> CompletableFuture<List<T>> lookupInSummaries(LookupFn<T> fn, Versioned<ITree> tree) {
            return latestAnalyzerAnalysis
                .thenCombine(latestBuilderBuild, (a, b) -> lookupInSummaries(fn, tree, a, b))
                .thenCompose(Function.identity());
        }

        /**
         * Dynamically routes the lookup to `analysis`, `build`, or a
         * single-shot. Note: Static routing is less suitable here, because
         * which summary to use depends on the version of `tree`, which is known
         * only dynamically.
         */
        private <T> CompletableFuture<List<T>> lookupInSummaries(
                LookupFn<T> fn, Versioned<ITree> tree,
                Versioned<ParametricSummary> analysis,
                Versioned<ParametricSummary> build) {

            // If a builder summary is available (i.e., a builder exists *and*
            // provides), and if it's of the right version, use that.
            var buildResult = fn.apply(build.get());
            if (buildResult != null && build.version() == tree.version()) {
                return buildResult.get().get();
            }

            // Else, if an analyzer summary is available (i.e., an analyzer
            // exists *and* provides), and if it's of the right version, use
            // that.
            var analysisResult = fn.apply(analysis.get());
            if (analysisResult != null && analysis.version() == tree.version()) {
                return analysisResult.get().get();
            }

            // Else, if a single-shooter summary is available, use that.
            return singleShotFactory
                .thenApply(f -> f.create(file, tree))
                .thenApply(singleShot -> {
                    var singleShotResult = fn.apply(singleShot);
                    if (singleShotResult != null) {
                        return singleShotResult.get().get();
                    } else {
                        return CompletableFuture.completedFuture(Collections.<T>emptyList());
                    }})
                .thenCompose(Function.identity());
        }
    }
}
