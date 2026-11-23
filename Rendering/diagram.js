import mermaid from "mermaid";

mermaid.initialize({
  startOnLoad: false,
  securityLevel: "strict",
  suppressErrorRendering: true,
  maxTextSize: 16_384,
  maxEdges: 100,
  htmlLabels: false,
  theme: "base",
  darkMode: true,
  themeVariables: {
    darkMode: true,
    background: "#191f25",
    primaryColor: "#23333c",
    primaryTextColor: "#eff4f8",
    primaryBorderColor: "#76dcc7",
    lineColor: "#9aaeb9",
    fontFamily: "-apple-system, sans-serif"
  }
});

window.renderDiagram = async source => {
  if (source.length > 16_384 || /^\s*---/.test(source) || source.includes("%%{")) return 0;
  const container = document.getElementById("diagram");
  try {
    const { svg } = await mermaid.render("riptide-diagram", source);
    container.innerHTML = svg;
    return Math.ceil(container.getBoundingClientRect().height);
  } catch {
    return 0;
  }
};
