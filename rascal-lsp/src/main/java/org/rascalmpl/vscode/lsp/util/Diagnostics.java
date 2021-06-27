/*
 * Copyright (c) 2018-2021, NWO-I CWI and Swat.engineering
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
package org.rascalmpl.vscode.lsp.util;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Map.Entry;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import org.eclipse.lsp4j.Diagnostic;
import org.eclipse.lsp4j.DiagnosticSeverity;
import org.eclipse.lsp4j.Position;
import org.eclipse.lsp4j.Range;
import org.rascalmpl.parser.gtd.exception.ParseError;
import org.eclipse.lsp4j.Range;
import org.rascalmpl.parser.gtd.exception.ParseError;
import org.rascalmpl.values.ValueFactoryFactory;
import org.rascalmpl.vscode.lsp.util.locations.ColumnMaps;
import org.rascalmpl.vscode.lsp.util.locations.Locations;

import io.usethesource.vallang.ICollection;
import io.usethesource.vallang.IConstructor;
import io.usethesource.vallang.ISourceLocation;
import io.usethesource.vallang.IString;
import io.usethesource.vallang.IValue;

public class Diagnostics {
    private static final Map<String, DiagnosticSeverity> severityMap;

    static {
        severityMap = new HashMap<>();
        severityMap.put("error", DiagnosticSeverity.Error);
        severityMap.put("warning", DiagnosticSeverity.Warning);
        severityMap.put("info", DiagnosticSeverity.Information);
    }

    public static <K, V> Map<K, List<V>> groupByKey(Stream<Entry<K, V>> diagnostics) {
        return diagnostics.collect(
            Collectors.groupingBy(Entry::getKey,
                Collectors.mapping(Entry::getValue, Collectors.toCollection(ArrayList::new))));
    }

    public static Diagnostic translateDiagnostic(ParseError e, ColumnMaps cm) {
        return new Diagnostic(toRange(e, cm), e.getMessage(), DiagnosticSeverity.Error, "parser");
    }

    public static Diagnostic translateRascalParseError(IValue e, ColumnMaps cm) {
        if (e instanceof IConstructor) {
            IConstructor error = (IConstructor) e;
            ISourceLocation loc = (ISourceLocation) error.get(0);
            return new Diagnostic(Locations.toRange(loc, cm), "parse error", DiagnosticSeverity.Error, "parser");
        }
        else {
            throw new IllegalArgumentException(e.toString());
        }
    }

    public static Diagnostic translateDiagnostic(IConstructor d, ColumnMaps cm) {
        Diagnostic result = new Diagnostic();
        result.setSeverity(severityMap.get(d.getName()));
        result.setMessage(((IString) d.get("msg")).getValue());
        result.setRange(Locations.toRange((ISourceLocation) d.get("at"), cm));
        return result;
    }

    private static Range toRange(ParseError pe, ColumnMaps cm) {
        ISourceLocation loc = pe.getLocation();
        if (loc.getBeginLine() == loc.getEndLine() && loc.getBeginColumn() == loc.getEndColumn()) {
            // zero width parse error is not something LSP likes, so we make it one char wider
            loc = ValueFactoryFactory.getValueFactory().sourceLocation(loc,
                loc.getOffset(), loc.getLength() + 1,
                loc.getBeginLine(), loc.getBeginColumn(),
                loc.getEndLine(), loc.getEndColumn() + 1);
        }
        return Locations.toRange(loc, cm);
    }

    public static List<Diagnostic> translateDiagnostics(ICollection<?> messages, ColumnMaps cm) {
        return messages.stream()
            .filter(IConstructor.class::isInstance)
            .map(IConstructor.class::cast)
            .map(d -> translateDiagnostic(d, cm))
            .collect(Collectors.toList());
    }
}
