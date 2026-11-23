import hljs from "highlight.js/lib/common";
import swift from "highlight.js/lib/languages/swift";
import rust from "highlight.js/lib/languages/rust";
import kotlin from "highlight.js/lib/languages/kotlin";
import yaml from "highlight.js/lib/languages/yaml";
import toml from "highlight.js/lib/languages/ini";

for (const [name, grammar] of Object.entries({swift, rust, kotlin, yaml, ini: toml})) {
  hljs.registerLanguage(name, grammar);
}

globalThis.highlightCode = (source, language) => {
  if (!hljs.getLanguage(language)) return null;
  return hljs.highlight(source, {language, ignoreIllegals: true}).value;
};
