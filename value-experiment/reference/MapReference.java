// MapReference.java — the bridge to the validator's StructureMap engine (value-experiment/PROTOCOL.md, H part 2).
//
//   javac -proc:none -cp validator_cli.jar -d OUT MapReference.java
//   java -cp validator_cli.jar:OUT MapReference PAIRS.jsonl ANSWERS.jsonl
//
// PAIRS.jsonl holds one JSON object a line, the pairs of one step together:
//   {"id": "...", "dir": "<the step's logical models>", "map": "<a map's text, a file>", "url": "<the map's url>",
//    "file": "<the source, a JSON file>"}
// For each, in order, one line is written: {"id": "...", "result": "<the result as JSON text>"}, or
// {"id": "...", "error": "<why the map was not read, or the exception's message>"}.
//
// What runs is what `java -jar validator_cli.jar transform` runs once it has a terminology server:
// FHIR 5.0.0, the core package, the step's logical models; the map parsed by the engine's own
// parser. This program loads, calls and prints. It compares nothing.

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.Map;

import com.google.gson.Gson;
import com.google.gson.JsonObject;

import org.hl7.fhir.model.fml.StructureMap;
import org.hl7.fhir.model.utilities.formats.FhirFormat;
import org.hl7.fhir.services.fml.StructureMapTools;
import org.hl7.fhir.validation.ValidationEngine;

public class MapReference {
  public static void main(String[] args) throws Exception {
    Gson gson = new Gson();
    String dir = null;
    ValidationEngine engine = null;
    Map<String, String> maps = new HashMap<>();   // map file -> "" when read, else why it was not
    long n = 0;
    try (BufferedReader in = Files.newBufferedReader(Paths.get(args[0]), StandardCharsets.UTF_8);
         BufferedWriter out = Files.newBufferedWriter(Paths.get(args[1]), StandardCharsets.UTF_8)) {
      String line;
      while ((line = in.readLine()) != null) {
        if (line.isEmpty()) continue;
        JsonObject pair = gson.fromJson(line, JsonObject.class);
        JsonObject answer = new JsonObject();
        answer.add("id", pair.get("id"));
        try {
          String d = pair.get("dir").getAsString();
          if (!d.equals(dir)) {
            engine = new ValidationEngine.ValidationEngineBuilder().withVersion("5.0.0").withNoTerminologyServer().fromSource("hl7.fhir.r5.core#5.0.0");
            String[] models = new java.io.File(d).list();
            if (models != null && models.length > 0) engine.getIgLoader().loadIg(engine.getIgs(), engine.getBinaries(), d, false);
            dir = d;
            maps.clear();
          }
          String mapFile = pair.get("map").getAsString();
          String why = maps.get(mapFile);
          if (why == null) {
            try {
              String text = new String(Files.readAllBytes(Paths.get(mapFile)), StandardCharsets.UTF_8);
              StructureMap map = new StructureMapTools(engine.getContext()).parse(text, mapFile);
              engine.getContext().cacheResource(map);
              why = "";
            } catch (Throwable e) { why = "map not read: " + e.getClass().getSimpleName() + ": " + e.getMessage(); }
            maps.put(mapFile, why);
          }
          if (!why.isEmpty()) throw new RuntimeException(why);
          byte[] result = engine.transform(Files.readAllBytes(Paths.get(pair.get("file").getAsString())), FhirFormat.JSON,
                                           pair.get("url").getAsString(), FhirFormat.JSON);
          answer.addProperty("result", new String(result, StandardCharsets.UTF_8));
        } catch (Throwable e) {
          answer.addProperty("error", e.getClass().getSimpleName() + ": " + e.getMessage());
        }
        out.write(gson.toJson(answer));
        out.newLine();
        if (++n % 500 == 0) System.err.println(n + " pairs");
      }
    }
    System.err.println(n + " pairs run");
  }
}
