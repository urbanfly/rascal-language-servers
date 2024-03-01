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

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.function.Function;
import java.util.function.Supplier;
import java.util.stream.Collectors;
import org.apache.logging.log4j.Logger;
import org.apache.logging.log4j.LogManager;
import org.checkerframework.checker.nullness.qual.Nullable;
import org.eclipse.lsp4j.Diagnostic;
import org.eclipse.lsp4j.Location;
import org.eclipse.lsp4j.MarkedString;
import org.eclipse.lsp4j.Position;
import org.eclipse.lsp4j.Range;
import org.eclipse.lsp4j.jsonrpc.messages.Either;
import org.rascalmpl.values.IRascalValueFactory;
import org.rascalmpl.values.parsetrees.ITree;
import org.rascalmpl.values.parsetrees.TreeAdapter;
import org.rascalmpl.vscode.lsp.parametric.ILanguageContributions;
import org.rascalmpl.vscode.lsp.parametric.ILanguageContributions.SummaryConfig;
import org.rascalmpl.vscode.lsp.util.Diagnostics;
import org.rascalmpl.vscode.lsp.util.Lazy;
import org.rascalmpl.vscode.lsp.util.Versioned;
import org.rascalmpl.vscode.lsp.util.concurrent.InterruptibleFuture;
import org.rascalmpl.vscode.lsp.util.locations.ColumnMaps;
import org.rascalmpl.vscode.lsp.util.locations.IRangeMap;
import org.rascalmpl.vscode.lsp.util.locations.Locations;
import org.rascalmpl.vscode.lsp.util.locations.impl.TreeMapLookup;
import io.usethesource.vallang.IConstructor;
import io.usethesource.vallang.IRelation;
import io.usethesource.vallang.ISet;
import io.usethesource.vallang.ISourceLocation;
import io.usethesource.vallang.IString;
import io.usethesource.vallang.ITuple;
import io.usethesource.vallang.IValue;
import io.usethesource.vallang.IWithKeywordParameters;

@SuppressWarnings("deprecation")
public interface Summary {
    public static final String KEY_DOCUMENTATION = "documentation";
    public static final String KEY_DEFINITIONS = "definitions";
    public static final String KEY_REFERENCES = "references";
    public static final String KEY_IMPLEMENTATIONS = "implementations";

    @Nullable Supplier<InterruptibleFuture<List<Either<String, MarkedString>>>> getDocumentation(Position cursor);
    @Nullable Supplier<InterruptibleFuture<List<Location>>> getDefinitions(Position cursor);
    @Nullable Supplier<InterruptibleFuture<List<Location>>> getReferences(Position cursor);
    @Nullable Supplier<InterruptibleFuture<List<Location>>> getImplementations(Position cursor);
    InterruptibleFuture<List<Diagnostic>> getMessages();
    void invalidate();

    public static final Summary NULL_SUMMARY = new Summary() {
        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Either<String, MarkedString>>>> getDocumentation(Position cursor) {
            return null;
        }
        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getDefinitions(Position cursor) {
            return null;
        }
        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getReferences(Position cursor) {
            return null;
        }
        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getImplementations(Position cursor) {
            return null;
        }
        @Override
        public InterruptibleFuture<List<Diagnostic>> getMessages() {
            return InterruptibleFuture.completedFuture(Collections.emptyList());
        }
        @Override
        public void invalidate() {
            // Nothing to invalidate
        }
    };

    public static InterruptibleFuture<List<Diagnostic>> getMessages(CompletableFuture<Versioned<Summary>> summary, Executor exec) {
        var messages = summary
            .thenApply(Versioned<Summary>::get)
            .thenApply(Summary::getMessages);
        return InterruptibleFuture.flatten(messages, exec);
    }
}

abstract class BaseSummaryFactory {
    protected final SummaryConfig config;
    protected final Executor exec;
    protected final ColumnMaps columns;
    protected final ILanguageContributions contrib;
    protected final ValueMapper valueMapper;

    protected BaseSummaryFactory(SummaryConfig config, Executor exec, ColumnMaps columns, ILanguageContributions contrib) {
        this.config = config;
        this.exec = exec;
        this.columns = columns;
        this.contrib = contrib;
        this.valueMapper = new ValueMapper(columns);
    }
}

@SuppressWarnings("deprecation")
class SummarizerSummaryFactory extends BaseSummaryFactory {
    private static final Logger logger = LogManager.getLogger(SummarizerSummaryFactory.class);

    public SummarizerSummaryFactory(SummaryConfig config, Executor exec, ColumnMaps columns, ILanguageContributions contrib) {
        super(config, exec, columns, contrib);
    }

    public Summary create(InterruptibleFuture<IConstructor> calculation) {
        return new SummarizerSummary(calculation);
    }

    public class SummarizerSummary implements Summary {
        public final @Nullable InterruptibleFuture<Lazy<IRangeMap<List<Either<String, MarkedString>>>>> documentation;
        public final @Nullable InterruptibleFuture<Lazy<IRangeMap<List<Location>>>> definitions;
        public final @Nullable InterruptibleFuture<Lazy<IRangeMap<List<Location>>>> references;
        public final @Nullable InterruptibleFuture<Lazy<IRangeMap<List<Location>>>> implementations;
        public final InterruptibleFuture<List<Diagnostic>> messages;

        public SummarizerSummary(InterruptibleFuture<IConstructor> calculation) {
            this.documentation = config.providesDocumentation ?
                mapCalculation(KEY_DOCUMENTATION, calculation, KEY_DOCUMENTATION, valueMapper::mapValueToString) : null;
            this.definitions = config.providesDefinitions ?
                mapCalculation(KEY_DEFINITIONS, calculation, KEY_DEFINITIONS, valueMapper::mapValueToLocation) : null;
            this.references = config.providesReferences ?
                mapCalculation(KEY_REFERENCES, calculation, KEY_REFERENCES, valueMapper::mapValueToLocation) : null;
            this.implementations = config.providesImplementations ?
                mapCalculation(KEY_IMPLEMENTATIONS, calculation, KEY_IMPLEMENTATIONS, valueMapper::mapValueToLocation) : null;
            this.messages = extractMessages(calculation);
        }

        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Either<String, MarkedString>>>> getDocumentation(Position cursor) {
            return documentation == null ? null : get(documentation, cursor);
        }

        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getDefinitions(Position cursor) {
            return definitions == null ? null : get(definitions, cursor);
        }

        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getReferences(Position cursor) {
            return references == null ? null : get(references, cursor);
        }

        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getImplementations(Position cursor) {
            return implementations == null ? null : get(implementations, cursor);
        }

        @Override
        public InterruptibleFuture<List<Diagnostic>> getMessages() {
            return messages;
        }

        @Override
        public void invalidate() {
            documentation.interrupt();
            definitions.interrupt();
            references.interrupt();
            implementations.interrupt();
            messages.interrupt();
        }

        private <T> InterruptibleFuture<Lazy<IRangeMap<List<T>>>> mapCalculation(String logName,
                InterruptibleFuture<IConstructor> calculation, String kwField, Function<IValue, T> valueMapper) {

            logger.trace("{}: Mapping summary by getting {}", logName, kwField);
            return calculation
                .thenApply(IConstructor::asWithKeywordParameters)
                .thenApply(s ->
                    Lazy.defer(() ->
                        translateRelation(logName, getKWFieldSet(s, kwField), valueMapper)));
        }

        private IRelation<ISet> getKWFieldSet(IWithKeywordParameters<? extends IConstructor> data, String name) {
            if (data.hasParameter(name)) {
                return ((ISet) data.getParameter(name)).asRelation();
            }
            return IRascalValueFactory.getInstance().set().asRelation();
        }

        private <T> IRangeMap<List<T>> translateRelation(String logName,
                IRelation<ISet> binaryRel, Function<IValue, T> mapValue) {

            logger.trace("{}: summary contain rel of size:{}", logName, binaryRel.asContainer().size());
            TreeMapLookup<List<T>> result = new TreeMapLookup<>();
            for (IValue v: binaryRel) {
                ITuple row = (ITuple)v;
                Range from = Locations.toRange((ISourceLocation)row.get(0), columns);
                T to = mapValue.apply(row.get(1));
                var existing = result.getExact(from);
                if (existing == null) {
                    // most cases there is only a single entry, to so save a lot of memory, we store a singleton list to start with
                    result.put(from, Collections.singletonList(to));
                }
                else if (existing.size() == 1) {
                    // we had a singleton list in there, so let's replace it with a regular list
                    existing = new ArrayList<>(existing);
                    result.put(from, existing);
                    existing.add(to);
                }
                else {
                    existing.add(to);
                }
            }
            return result;
        }

        private InterruptibleFuture<List<Diagnostic>> extractMessages(InterruptibleFuture<IConstructor> summary) {
            return summary.thenApply(s -> {
                var sum = s.asWithKeywordParameters();
                if (sum.hasParameter("messages")) {
                    return ((ISet)sum.getParameter("messages")).stream()
                        .map(d -> Diagnostics.translateDiagnostic((IConstructor)(((ITuple)d).get(1)), columns))
                        .collect(Collectors.toList());
                }
                return Collections.emptyList();
            });
        }

        private <T> Supplier<InterruptibleFuture<List<T>>> get(InterruptibleFuture<Lazy<IRangeMap<List<T>>>> result, Position cursor) {
            return () -> result
                .thenApplyAsync(Lazy::get, exec)
                .thenApply(l -> l.lookup(new Range(cursor, cursor)))
                .thenApply(r -> r == null ? Collections.emptyList() : r);
        }
    }
}

@FunctionalInterface
interface DedicatedLookupFunction {
    InterruptibleFuture<ISet> lookup(ISourceLocation file, ITree tree, ITree cursor);
}

@SuppressWarnings("deprecation")
class DedicatedLookupFunctionsSummaryFactory extends BaseSummaryFactory {
    private static final Logger logger = LogManager.getLogger(DedicatedLookupFunctionsSummaryFactory.class);

    public DedicatedLookupFunctionsSummaryFactory(SummaryConfig config, Executor exec, ColumnMaps columns, ILanguageContributions contrib) {
        super(config, exec, columns, contrib);
    }

    public Summary create(ISourceLocation file, CompletableFuture<Versioned<ITree>> tree) {
        return new Lookups(file, tree);
    }

    public class Lookups implements Summary {
        private final ISourceLocation file;
        private final CompletableFuture<Versioned<ITree>> tree;

        public Lookups(ISourceLocation file, CompletableFuture<Versioned<ITree>> tree) {
            this.file = file;
            this.tree = tree;
        }

        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Either<String, MarkedString>>>> getDocumentation(Position cursor) {
            return config.providesDocumentation ? get(cursor, contrib::documentation, valueMapper::mapValueToString, KEY_DOCUMENTATION) : null;
        }

        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getDefinitions(Position cursor) {
            return config.providesDefinitions ? get(cursor, contrib::definitions, valueMapper::mapValueToLocation, KEY_DEFINITIONS) : null;
        }

        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getReferences(Position cursor) {
            return config.providesReferences ? get(cursor, contrib::references, valueMapper::mapValueToLocation, KEY_REFERENCES) : null;
        }

        @Override
        public @Nullable Supplier<InterruptibleFuture<List<Location>>> getImplementations(Position cursor) {
            return config.providesImplementations ? get(cursor, contrib::implementations, valueMapper::mapValueToLocation, KEY_IMPLEMENTATIONS) : null;
        }

        @Override
        public InterruptibleFuture<List<Diagnostic>> getMessages() {
            return InterruptibleFuture.completedFuture(Collections.emptyList());
        }

        @Override
        public void invalidate() {
            // Nothing to invalidate
        }

        private <T> Supplier<InterruptibleFuture<List<T>>> get(Position cursor,
                DedicatedLookupFunction function, Function<IValue, T> valueMapper, String logName) {

            return () -> {
                var result = tree
                        .thenApplyAsync(t -> {
                            var line = cursor.getLine() + 1;
                            var translatedOffset = columns.get(file).translateInverseColumn(line, cursor.getCharacter(), false);
                            var cursorTree = TreeAdapter.locateLexical(t.get(), line, translatedOffset);
                            if (cursorTree == null) {
                                logger.trace("{}: could not find substree at line {} and offset {}", logName, line, translatedOffset);
                                return InterruptibleFuture.completedFuture(IRascalValueFactory.getInstance().set());
                            }
                            logger.trace("{}: looked up cursor to: {}, now calling dedicated function", logName, TreeAdapter.yield(cursorTree));
                            var set = function.lookup(file, t.get(), cursorTree);
                            logger.trace("{}: dedicated returned: {}", logName, set);
                            return set;
                        }, exec);

                return InterruptibleFuture.flatten(result, exec)
                    .thenApply(s -> toList(s, valueMapper));
            };
        }

        private <T> List<T> toList(ISet s, Function<IValue, T> valueMapper) {
            if (s == null || s.isEmpty()) {
                return Collections.emptyList();
            }
            int size = s.size();
            if (size == 1) {
                var v = s.iterator().next();
                return Collections.singletonList(valueMapper.apply(v));
            }
            var list = new ArrayList<T>(size);
            for (IValue v : s) {
                list.add(valueMapper.apply(v));
            }
            return list;
        }
    }
}

@SuppressWarnings("deprecation")
class ValueMapper {
    private final ColumnMaps columns;

    public ValueMapper(ColumnMaps columns) {
        this.columns = columns;
    }

    public Location mapValueToLocation(IValue v) {
        return Locations.toLSPLocation((ISourceLocation)v, columns);
    }

    public Either<String, MarkedString> mapValueToString(IValue v) {
        return Either.forLeft(((IString) v).getValue());
    }
}
