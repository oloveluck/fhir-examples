// FhirPathReference.java — the bridge to HL7's Java FHIRPath engine (value-experiment/PROTOCOL.md, H).
//
//   javac -proc:none -cp validator_cli.jar -d OUT FhirPathReference.java
//   java -cp validator_cli.jar:OUT FhirPathReference PAIRS.jsonl ANSWERS.jsonl
//
// PAIRS.jsonl holds one JSON object a line: {"id": "...", "file": "<a FHIR JSON resource>", "expr": "<FHIRPath>"}.
// For each, in order, one line is written to ANSWERS.jsonl:
//   {"id": "...", "error": "<the exception's message>"}        the engine raised
//   {"id": "...", "items": [Item, ...]}                         the result, in the engine's order
// An Item is {"t": <fhirType>, "v": <primitive value or null>} for a primitive, else
// {"t": <fhirType>, "element": <is it part of the resource>, "leaves": [[<path>, <fhirType>, <value>], ...]}:
// its primitive descendants, each with the element names that lead to it.
//
// What is evaluated is what `java -jar validator_cli.jar fhirpath` evaluates: the validator's own
// engine over its element model of the resource, FHIR 4.0.1, the core package, no terminology
// server. This program calls the engine and prints what it returned. It compares nothing.

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;

import org.hl7.fhir.model.Base;
import org.hl7.fhir.model.Property;
import org.hl7.fhir.model.utilities.formats.FhirFormat;
import org.hl7.fhir.services.elementmodel.Element;
import org.hl7.fhir.services.elementmodel.Manager;
import org.hl7.fhir.services.fhirpath.ExpressionNode;
import org.hl7.fhir.services.fhirpath.FHIRPathEngine;
import org.hl7.fhir.validation.ValidationEngine;
import org.hl7.fhir.validation.instance.utils.ValidationContext;

public class FhirPathReference {

  // leaves : the primitive descendants of a value, each [path, type, value]
  static void leaves(Base x, String path, JsonArray out, int depth) {
    if (depth > 40) return;
    if (x instanceof Element) {
      for (Element c : ((Element) x).getChildren()) leaf(c, path.isEmpty() ? c.getName() : path + "." + c.getName(), out, depth);
    } else {
      for (Property p : x.getChildren())
        for (Base v : p.getValues()) leaf(v, path.isEmpty() ? p.getName() : path + "." + p.getName(), out, depth);
    }
  }

  static void leaf(Base c, String path, JsonArray out, int depth) {
    if (c.isPrimitive() && c.primitiveValue() != null) {
      JsonArray l = new JsonArray();
      l.add(path); l.add(c.fhirType()); l.add(c.primitiveValue());
      out.add(l);
    }
    leaves(c, path, out, depth + 1);
  }

  static JsonObject item(Base x) {
    JsonObject o = new JsonObject();
    o.addProperty("t", x.fhirType());
    if (x.isPrimitive()) {
      if (x.primitiveValue() == null) o.add("v", JsonNull.INSTANCE); else o.addProperty("v", x.primitiveValue());
    } else {
      o.addProperty("element", x instanceof Element);
      JsonArray l = new JsonArray();
      leaves(x, "", l, 0);
      o.add("leaves", l);
    }
    return o;
  }

  public static void main(String[] args) throws Exception {
    ValidationEngine engine = new ValidationEngine.ValidationEngineBuilder()
        .withVersion("4.0.1").withNoTerminologyServer().fromSource("hl7.fhir.r4.core#4.0.1");
    FHIRPathEngine fpe = engine.getValidator(null).getFHIRPathEngine();
    Gson gson = new Gson();
    Map<String, Object> resources = new HashMap<>();   // file -> Element, or the message of why it did not read
    Map<String, Object> expressions = new HashMap<>(); // text -> ExpressionNode, or the message of why it did not parse
    long n = 0;
    try (BufferedReader in = Files.newBufferedReader(Paths.get(args[0]), StandardCharsets.UTF_8);
         BufferedWriter out = Files.newBufferedWriter(Paths.get(args[1]), StandardCharsets.UTF_8)) {
      String line;
      while ((line = in.readLine()) != null) {
        if (line.isEmpty()) continue;
        JsonObject pair = gson.fromJson(line, JsonObject.class);
        String file = pair.get("file").getAsString();
        String expr = pair.get("expr").getAsString();
        JsonObject answer = new JsonObject();
        answer.add("id", pair.get("id"));
        try {
          Object r = resources.get(file);
          if (r == null) {
            try {
              r = Manager.parseSingle(engine.getContext(), new ByteArrayInputStream(Files.readAllBytes(Paths.get(file))), FhirFormat.JSON);
            } catch (Throwable e) { r = "resource not read: " + e.getMessage(); }
            if (r == null) r = "resource not read";
            resources.put(file, r);
          }
          if (r instanceof String) throw new RuntimeException((String) r);
          Object x = expressions.get(expr);
          if (x == null) {
            try { x = fpe.parse(expr); } catch (Throwable e) { x = "" + e.getMessage(); }
            expressions.put(expr, x);
          }
          if (x instanceof String) throw new RuntimeException((String) x);
          Element e = (Element) r;
          List<Base> result = fpe.evaluate(new ValidationContext(e), e, e, e, (ExpressionNode) x);
          JsonArray items = new JsonArray();
          for (Base b : result) items.add(item(b));
          answer.add("items", items);
        } catch (Throwable e) {
          answer.remove("items");
          answer.addProperty("error", e.getClass().getSimpleName() + ": " + e.getMessage());
        }
        out.write(gson.toJson(answer));
        out.newLine();
        if (++n % 20000 == 0) System.err.println(n + " pairs");
      }
    }
    System.err.println(n + " pairs evaluated");
  }
}
