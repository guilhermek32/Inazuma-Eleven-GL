// Gera docs/relatorio/Relatorio_Inazuma_Eleven_GL.docx a partir do repositório,
// formatado segundo a ABNT (NBR 14724:2011, 6023:2018, 6024:2012, 6027:2012,
// 6028:2021 e 10520:2023).
// Uso: npm install docx@9 && node gerar_relatorio.js <raiz do repositório> [páginas.txt]
// O sumário e as listas são texto fixo (funcionam em Word, LibreOffice e Google
// Docs). Os números de página vêm de uma primeira passada: gerar sem o arquivo de
// páginas (números provisórios), converter para PDF, extrair o texto com
// `pdftotext -layout` e gerar de novo passando esse texto.
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, ImageRun, Header, PageNumber, LevelFormat, ExternalHyperlink,
  LineRuleType, TabStopType, VerticalAlign, LeaderType,
} = require("docx");

const ROOT = process.argv[2];
const PAGES_TXT = process.argv[3];
const rd = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8").replace(/\r\n/g, "\n");
const REPO_URL = "https://github.com/guilhermek32/Inazuma-Eleven-GL";
const AUTHORS = ["ERICK KEVEN DA SILVA ALVES", "ANTONIO GUILHERME DA SILVA"];
const YEAR = "2026";
const ACESSO = "Acesso em: 29 out. 2026.";
const FONT = "Arial";
const MONO = "Courier New";
const AUTO = LineRuleType.AUTO;
// A4; margens ABNT: superior e esquerda 3 cm, inferior e direita 2 cm.
const CM = 567;
const TEXT_W = 11906 - 3 * CM - 2 * CM;
const LINE_15 = 360;   // espaçamento 1,5
const LINE_1 = 240;    // espaçamento simples
const INDENT = Math.round(1.25 * CM);   // recuo de primeira linha do parágrafo
const FONTE_AUTORES = `Elaborado pelos autores (${YEAR}).`;
const FONTE_TELA = `Captura de tela do sistema, elaborada pelos autores (${YEAR}).`;
const FONTE_REPO = `Repositório do projeto (${YEAR}).`;

// ---------------------------------------------------------------- auxiliares
let children = [];

function runs(text, base = {}) {
  // **negrito**, *itálico*, `código`
  const out = [];
  const re = /(\*\*[^*]+\*\*|\*[A-Za-zÀ-ÿ][^*]*\*|`[^`]+`)/g;
  let last = 0, m;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(new TextRun({ text: text.slice(last, m.index), ...base }));
    const t = m[0];
    if (t.startsWith("**")) out.push(new TextRun({ text: t.slice(2, -2), bold: true, ...base }));
    else if (t.startsWith("*")) out.push(new TextRun({ text: t.slice(1, -1), italics: true, ...base }));
    else out.push(new TextRun({ text: t.slice(1, -1), font: MONO, ...base, size: (base.size || 24) - 2 }));
    last = m.index + t.length;
  }
  if (last < text.length) out.push(new TextRun({ text: text.slice(last), ...base }));
  return out;
}
// Parágrafo de texto: justificado, 1,5, recuo de 1,25 cm na primeira linha.
const P = (text, opts = {}) => children.push(new Paragraph({ children: runs(text), alignment: AlignmentType.JUSTIFIED,
  indent: { firstLine: INDENT }, spacing: { line: LINE_15, lineRule: AUTO, after: 0 }, ...opts }));
const blank = () => children.push(new Paragraph({ spacing: { line: LINE_15, lineRule: AUTO, after: 0 }, children: [] }));
// Títulos (NBR 6024): primária em maiúsculas e negrito, em página nova; secundária
// em maiúsculas sem negrito; terciária em negrito com minúsculas. Alinhados à
// esquerda, separados do texto por um espaço de 1,5.
// Cada título e legenda é registrado para o sumário e as listas.
const tocEntries = [], figEntries = [], quadEntries = [], codEntries = [];
const H1 = (t, newPage = true) => { tocEntries.push({ level: 1, text: t });
  children.push(new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: newPage, children: [new TextRun(t)] })); };
const H2 = (t) => { tocEntries.push({ level: 2, text: t });
  children.push(new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(t)] })); };
const H3 = (t) => { tocEntries.push({ level: 3, text: t });
  children.push(new Paragraph({ heading: HeadingLevel.HEADING_3, children: [new TextRun(t)] })); };
// Título pós-textual sem indicativo numérico, centralizado, listado no sumário.
const H1u = (t) => { tocEntries.push({ level: 0, text: t });
  children.push(new Paragraph({ heading: HeadingLevel.HEADING_1, alignment: AlignmentType.CENTER,
    pageBreakBefore: true, children: [new TextRun(t)] })); };
// Alíneas (NBR 6024): a), b), c)...; terminam em ponto e vírgula, a última em ponto.
let alineaRef = 0;
function alineas(items) {
  const ref = `alineas${alineaRef++}`;
  numberingConfigs.push({ reference: ref, levels: [{ level: 0, format: LevelFormat.LOWER_LETTER, text: "%1)",
    alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: INDENT + 360, hanging: 360 } } } }] });
  items.forEach((t) => children.push(new Paragraph({ children: runs(t), numbering: { reference: ref, level: 0 },
    alignment: AlignmentType.JUSTIFIED, spacing: { line: LINE_15, lineRule: AUTO, after: 0 } })));
}
const numberingConfigs = [];

// Ilustrações e quadros (NBR 14724): título acima, precedido da palavra
// designativa e do número de ordem; fonte abaixo; letra menor.
const LISTS = { Figura: figEntries, Quadro: quadEntries, "Código": codEntries };
function caption(label, title, align) {
  const list = LISTS[label];
  const n = list.length + 1;
  list.push({ text: `${label} ${n} – ${title.replace(/`/g, "")}`, key: `${label} ${n} –` });
  children.push(new Paragraph({ alignment: align, keepNext: true, keepLines: true,
    spacing: { before: 240, after: 60, line: LINE_1, lineRule: AUTO },
    children: [new TextRun({ text: `${label} ${n} – `, size: 20 }), ...runs(title, { size: 20 })] }));
}
function source(text, align) {
  children.push(new Paragraph({ alignment: align, spacing: { before: 60, after: 240, line: LINE_1, lineRule: AUTO },
    children: [new TextRun({ text: "Fonte: ", size: 20 }), ...runs(text, { size: 20 })] }));
}

function pngSize(file) {
  const b = fs.readFileSync(file);
  return [b.readUInt32BE(16), b.readUInt32BE(20)];
}
function figure(file, title, fonte = FONTE_AUTORES, maxWcm = 16, maxHcm = 11) {
  const [w, h] = pngSize(file);
  let wc = maxWcm, hc = (h / w) * wc;
  if (hc > maxHcm) { hc = maxHcm; wc = (w / h) * hc; }
  caption("Figura", title, AlignmentType.CENTER);
  children.push(new Paragraph({ alignment: AlignmentType.CENTER, keepNext: true,
    spacing: { line: LINE_1, lineRule: AUTO, after: 0 },
    children: [new ImageRun({ type: "png", data: fs.readFileSync(file),
      transformation: { width: Math.round(wc * 37.8), height: Math.round(hc * 37.8) } })] }));
  source(fonte, AlignmentType.CENTER);
}

// Quadro (informação textual): bordas fechadas, letra menor, espaçamento simples.
function quadro(title, headers, rows, widths, fonte = FONTE_AUTORES) {
  const total = widths.reduce((a, b) => a + b, 0);
  const w = widths.map((x) => Math.floor((x * TEXT_W) / total));
  w[w.length - 1] += TEXT_W - w.reduce((a, b) => a + b, 0);
  caption("Quadro", title, AlignmentType.LEFT);
  const border = { style: BorderStyle.SINGLE, size: 4, color: "000000" };
  const borders = { top: border, bottom: border, left: border, right: border };
  const cell = (text, i, head) => new TableCell({
    width: { size: w[i], type: WidthType.DXA }, borders, verticalAlign: VerticalAlign.CENTER,
    shading: head ? { type: ShadingType.CLEAR, fill: "E7E6E6", color: "auto" } : undefined,
    margins: { top: 40, bottom: 40, left: 80, right: 80 },
    children: String(text).split("\n").map((t) => new Paragraph({ spacing: { after: 0, line: LINE_1, lineRule: AUTO },
      alignment: head ? AlignmentType.CENTER : AlignmentType.LEFT,
      children: runs(t, head ? { bold: true, size: 20 } : { size: 20 }) })),
  });
  children.push(new Table({
    width: { size: TEXT_W, type: WidthType.DXA }, columnWidths: w,
    rows: [new TableRow({ tableHeader: true, children: headers.map((h, i) => cell(h, i, true)) }),
      ...rows.map((r) => new TableRow({ cantSplit: true, children: r.map((c, i) => cell(c, i, false)) }))],
  }));
  source(fonte, AlignmentType.LEFT);
}

// Código-fonte documentado: ilustração do tipo "Código", em fonte monoespaçada.
function code(text, title, fonte = FONTE_REPO) {
  const lines = text.replace(/\t/g, "    ").replace(/\s+$/, "").split("\n");
  if (title) caption("Código", title, AlignmentType.LEFT);
  const bd = { style: BorderStyle.SINGLE, size: 4, color: "808080", space: 2 };
  lines.forEach((l, i) => children.push(new Paragraph({
    children: [new TextRun({ text: l === "" ? " " : l, font: MONO, size: 15 })],
    shading: { type: ShadingType.CLEAR, fill: "F2F2F2", color: "auto" },
    spacing: { before: 0, after: 0, line: LINE_1, lineRule: AUTO },
    border: { left: bd, right: bd, ...(i === 0 ? { top: bd } : {}), ...(i === lines.length - 1 ? { bottom: bd } : {}) },
    indent: { left: 113, right: 113 },
  })));
  if (title) source(fonte, AlignmentType.LEFT);
  else blank();
}

function pyDoc(rel) {
  const m = rd(rel).match(/^"""[\s\S]*?"""/);
  return m ? m[0] : "";
}
function gdHeader(rel) {
  const out = [];
  for (const l of rd(rel).split("\n")) {
    if (out.length === 0 && (l.startsWith("class_name") || l.startsWith("extends") || l.trim() === "")) { out.push(l); continue; }
    if (l.startsWith("##")) { out.push(l); continue; }
    if (out.some((x) => x.startsWith("##"))) break;
    out.push(l);
  }
  return out.join("\n").trim();
}
function between(rel, startRe, endRe) {
  const lines = rd(rel).split("\n");
  const a = lines.findIndex((l) => startRe.test(l));
  if (a < 0) throw new Error(`${rel}: ${startRe} não encontrado`);
  let b = lines.findIndex((l, i) => i > a && endRe.test(l));
  if (b < 0) b = lines.length;
  return lines.slice(a, b).join("\n");
}
const IMG = (f) => path.join(ROOT, "docs/relatorio/img", f);

// Linha centralizada dos elementos pré-textuais.
const centered = (text, opts = {}) => new Paragraph({ alignment: AlignmentType.CENTER,
  spacing: { line: LINE_15, lineRule: AUTO, before: opts.before || 0, after: opts.after || 0 },
  pageBreakBefore: opts.pageBreak || false,
  children: [new TextRun({ text, bold: opts.bold, size: opts.size || 24, color: opts.color })] });

// ================================================================ CAPA
const capa = [];
capa.push(centered("UNIVERSIDADE FEDERAL DE ALAGOAS", { bold: true }));
capa.push(centered("ENGENHARIA DE SOFTWARE", { bold: true, after: 1400 }));
AUTHORS.forEach((a) => capa.push(centered(a, { bold: true })));
capa.push(centered("INAZUMA ELEVEN GL:", { bold: true, before: 2600 }));
capa.push(centered("um jogo digital não violento usando microservices e componentes de software", { bold: true }));
capa.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 1000, after: 0, line: LINE_1, lineRule: AUTO },
  children: [new TextRun({ text: "Código no GitHub: ", size: 20 }),
    new ExternalHyperlink({ link: REPO_URL, children: [new TextRun({ text: REPO_URL, style: "Hyperlink", size: 20 })] })] }));
capa.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 60, after: 0, line: LINE_1, lineRule: AUTO },
  children: [new TextRun({ text: "Vídeo de demonstração: ", size: 20 }),
    new TextRun({ text: "[inserir link do vídeo]", size: 20, color: "C00000" })] }));
capa.push(centered("Maceió", { bold: true, before: 3000 }));
capa.push(centered(YEAR, { bold: true }));

// ================================================================ PRÉ-TEXTUAIS
const pre = [];
// Folha de rosto
AUTHORS.forEach((a) => pre.push(centered(a, { bold: true })));
pre.push(centered("INAZUMA ELEVEN GL:", { bold: true, before: 3000 }));
pre.push(centered("um jogo digital não violento usando microservices e componentes de software", { bold: true, after: 1000 }));
pre.push(new Paragraph({ alignment: AlignmentType.JUSTIFIED, indent: { left: 8 * CM },
  spacing: { line: LINE_1, lineRule: AUTO, after: 240 },
  children: [new TextRun({ text: "Relatório de projeto apresentado à disciplina de Engenharia de Software da Universidade Federal de Alagoas, como requisito parcial para aprovação na disciplina.", size: 20 })] }));
pre.push(new Paragraph({ alignment: AlignmentType.JUSTIFIED, indent: { left: 8 * CM },
  spacing: { line: LINE_1, lineRule: AUTO, after: 0 },
  children: [new TextRun({ text: "Professor(a): [preencher]", size: 20 })] }));
pre.push(centered("Maceió", { bold: true, before: 3600 }));
pre.push(centered(YEAR, { bold: true }));

// Resumo e abstract (NBR 6028): parágrafo único seguido das palavras-chave.
const titleNoNum = (t) => new Paragraph({ style: "TituloSemNumero", alignment: AlignmentType.CENTER, pageBreakBefore: true, children: [new TextRun(t)] });
const resumoPar = (text) => new Paragraph({ alignment: AlignmentType.JUSTIFIED, spacing: { line: LINE_15, lineRule: AUTO, after: 0 }, children: runs(text) });
pre.push(titleNoNum("RESUMO"));
pre.push(resumoPar("Este relatório apresenta o Inazuma Eleven GL, um jogo digital não violento de futebol arcade 11 contra 11 em 3D, desenvolvido em Godot 4.7, que roda no navegador e no desktop, com partidas offline e online. A parte online foi construída como um sistema de microsserviços independentes (lobby, match runtime, results, ai-bot e recommendation) atrás de um API Gateway (Caddy), implantado com Docker Compose, e o jogo é organizado em componentes de software reutilizados pelo cliente, pelo servidor autoritativo e pelo bot de inteligência artificial. O trabalho foi conduzido com a metodologia ágil Scrum, em seis sprints registradas no histórico do repositório, e aplicou como técnicas de reuso os microsserviços e os componentes de software, além do reuso de frameworks. Um sistema de recomendação, implementado como microsserviço, calcula um rating Elo de cada jogador a partir do histórico de partidas e recomenda o nível da IA adversária e rivais de nível semelhante. O relatório descreve a modelagem (metodologia, backlogs, arquitetura, gateway, especificação de cada microsserviço e componente, sistema de recomendação) e a implementação (tecnologias, telas do sistema, código no GitHub e vídeo). Os serviços e componentes são verificados por testes automatizados executados em integração contínua."));
pre.push(new Paragraph({ spacing: { before: LINE_15, line: LINE_15, lineRule: AUTO, after: 0 }, alignment: AlignmentType.JUSTIFIED,
  children: runs("**Palavras-chave:** jogo digital; microsserviços; componentes de software; sistema de recomendação; Scrum.") }));
pre.push(titleNoNum("ABSTRACT"));
pre.push(resumoPar("This report presents Inazuma Eleven GL, a nonviolent digital game of 11-a-side arcade football in 3D, developed in Godot 4.7, which runs in the browser and on the desktop, with offline and online matches. The online part was built as a system of independent microservices (lobby, match runtime, results, ai-bot and recommendation) behind an API Gateway (Caddy), deployed with Docker Compose, and the game is organized into software components reused by the client, by the authoritative server and by the artificial intelligence bot. The work followed the Scrum agile methodology, in six sprints recorded in the repository history, and applied microservices and software components as reuse techniques, together with framework reuse. A recommender system, implemented as a microservice, computes an Elo rating for each player from the match history and recommends the level of the opposing AI and rivals of similar skill. The report describes the modeling (methodology, backlogs, architecture, gateway, specification of each microservice and component, recommender system) and the implementation (technologies, system screens, code on GitHub and video). The services and components are verified by automated tests run in continuous integration."));
pre.push(new Paragraph({ spacing: { before: LINE_15, line: LINE_15, lineRule: AUTO, after: 0 }, alignment: AlignmentType.JUSTIFIED,
  children: runs("**Keywords:** digital game; microservices; software components; recommender system; Scrum.") }));

// Listas de ilustrações, de quadros e o sumário são montados no fim (buildLists),
// depois que o texto registrou todos os títulos e legendas.
function buildLists(pageOf) {
// Lista de ilustrações / quadros / códigos (NBR 14724): ordem do texto, com a página.
const leaderTabs = (left) => [
  ...(left ? [{ type: TabStopType.LEFT, position: left }] : []),
  { type: TabStopType.RIGHT, position: TEXT_W, leader: LeaderType.DOT }];
const lista = (title, entries) => {
  pre.push(titleNoNum(title));
  entries.forEach((e) => pre.push(new Paragraph({ tabStops: leaderTabs(0), alignment: AlignmentType.LEFT,
    spacing: { line: LINE_15, lineRule: AUTO, after: 0 },
    children: [new TextRun(e.text), new TextRun("\t" + pageOf(e))] })));
};
lista("LISTA DE FIGURAS", figEntries);
lista("LISTA DE QUADROS", quadEntries);
lista("LISTA DE CÓDIGOS", codEntries);
// Lista de abreviaturas e siglas
pre.push(titleNoNum("LISTA DE ABREVIATURAS E SIGLAS"));
[["API", "Application Programming Interface (interface de programação de aplicações)"],
 ["CI", "Continuous Integration (integração contínua)"],
 ["COTS", "Commercial Off-The-Shelf (software pronto de terceiros)"],
 ["DDA", "Dynamic Difficulty Adjustment (ajuste dinâmico de dificuldade)"],
 ["e2e", "End-to-end (teste de ponta a ponta)"],
 ["HMAC", "Hash-based Message Authentication Code"],
 ["HTTP", "Hypertext Transfer Protocol"],
 ["HTTPS", "HTTP sobre TLS"],
 ["IA", "Inteligência Artificial"],
 ["JSON", "JavaScript Object Notation"],
 ["PvP", "Player versus Player (jogador contra jogador)"],
 ["REST", "Representational State Transfer"],
 ["SQL", "Structured Query Language"],
 ["TLS", "Transport Layer Security"],
 ["UUID", "Universally Unique Identifier"],
 ["WSS", "WebSocket seguro (sobre TLS)"],
].forEach(([s, d]) => pre.push(new Paragraph({ spacing: { line: LINE_15, lineRule: AUTO, after: 0 },
  indent: { left: 2 * CM, hanging: 2 * CM },
  tabStops: [{ type: TabStopType.LEFT, position: 2 * CM }], children: [new TextRun(s), new TextRun("\t" + d)] })));
// Sumário (NBR 6027): indicativo numérico à esquerda, títulos alinhados pela
// margem do indicativo mais extenso, mesma ênfase tipográfica do texto, página.
pre.push(titleNoNum("SUMÁRIO"));
const NUM_W = Math.round(1.5 * CM);
tocEntries.forEach((e) => {
  const m = e.text.match(/^([\d.]+) (.*)$/);
  const num = m ? m[1] : "", title = m ? m[2] : e.text;
  const style = { bold: e.level === 1 || e.level === 3 || e.level === 0 };
  pre.push(new Paragraph({ tabStops: leaderTabs(NUM_W), alignment: AlignmentType.LEFT,
    indent: m ? { left: NUM_W, hanging: NUM_W } : undefined,
    spacing: { line: LINE_15, lineRule: AUTO, after: 0 },
    children: [new TextRun({ text: m ? `${num}\t${title}` : title, ...style }), new TextRun({ text: "\t" + pageOf(e), ...style })] }));
});
}

// ================================================================ TEXTUAIS
children = [];

// ---------------------------------------------------------------- 1 Introdução
H1("1 INTRODUÇÃO", false);   // a seção já começa em página nova
P("Este relatório documenta o projeto da disciplina de Engenharia de Software cujo tema é “Um Jogo Digital não Violento Usando Microservices e Componentes de Software”. Nele se descrevem a modelagem e a implementação do **Inazuma Eleven GL**, um jogo de futebol em 3D cuja parte online é um sistema de microsserviços.");
H2("1.1 ENUNCIADO DO PROJETO BASEADO EM MICROSSERVIÇOS");
P("O projeto é o Inazuma Eleven GL, um jogo de futebol arcade 11 contra 11 em 3D, inspirado na série Inazuma Eleven. Ele roda no navegador (WebAssembly) e no desktop, com partidas offline (contra a IA ou com dois jogadores no mesmo computador) e online (contra um amigo, por código de sala, ou contra um adversário de IA hospedado no servidor). A parte online foi construída como um sistema de **microsserviços**, isto é, serviços pequenos e implantáveis de forma independente, cada um com processo e dados próprios, que se comunicam por mecanismos leves como HTTP (FOWLER; LEWIS, 2014; NEWMAN, 2021). O jogo é organizado em **componentes de software**, unidades de composição com interfaces especificadas contratualmente e dependências explícitas de contexto (SZYPERSKI, 2002), reutilizadas pelo cliente, pelo servidor e pelo bot.");
P("O jogo é **não violento**. O objetivo é marcar gols com passe, posicionamento e trabalho em equipe. O desarme (*tackle*) serve apenas para recuperar a bola; não há sangue, lesão, dano, barra de vida nem recompensa por atingir jogadores. Um desarme por trás é falta e dá tiro livre ao adversário (fair play). Os chutes especiais (*hissatsu*) são efeitos visuais aplicados à bola, e as estatísticas exibidas são posse de bola, finalizações, chutes no gol, desarmes, faltas e impedimentos. O Quadro 1 relaciona os requisitos do enunciado às evidências no projeto.");
quadro("Matriz de requisitos do enunciado", ["Requisito", "Como o projeto atende", "Onde verificar"], [
  ["Jogo digital", "Futebol 11x11 em 3D (Godot 4.7), offline e online, no navegador e no desktop.", "scenes/main_3d.tscn; scripts/match_controller_3d.gd"],
  ["Não violento", "Desarme só recupera a bola; desarme por trás é falta; sem dano, sangue ou eliminação.", "scripts/systems/match_simulation.gd; ARCHITECTURE_ONLINE.md, seção 9"],
  ["Microsserviços", "Cinco serviços de negócio (lobby, match runtime, results, ai-bot e recommendation), cada um com processo, imagem Docker, testes, health check e dados próprios, conversando só por contratos HTTP/WebSocket versionados atrás de um gateway.", "docker-compose.yml; services/; scripts/server; scripts/bot"],
  ["Componentes de software", "MatchSession/MatchConfig, NetProtocol, MatchToken/credentials.py, Tactics, ControlServer, LobbyClient e ServiceStatusPanel, cada um usado por mais de um adaptador.", "scripts/match; scripts/net; scripts/ai; scripts/server; scripts/systems"],
  ["Sistema de recomendação", "Microsserviço recommendation: rating Elo de cada jogador a partir do histórico de partidas, recomendação do nível da IA e de rivais do mesmo nível.", "services/recommendation; painel “Recommended for you”"],
], [2.2, 5, 3.2]);
H2("1.2 OBJETIVOS");
P("O objetivo geral é desenvolver um jogo digital não violento cuja parte online seja um sistema de microsserviços e cujo código seja organizado em componentes de software reutilizáveis. Os objetivos específicos são:");
alineas([
  "implementar a simulação da partida como um componente reutilizado offline, no servidor e pelo bot;",
  "separar o sistema online em microsserviços com dados próprios, atrás de um API Gateway;",
  "oferecer um sistema de recomendação de nível de IA e de rivais baseado no desempenho dos jogadores;",
  "evidenciar na interface do jogo quais microsserviços estão em execução e quais cada ação usa;",
  "conduzir o desenvolvimento com Scrum e verificar o sistema com testes automatizados em integração contínua.",
]);
H2("1.3 ORGANIZAÇÃO DO RELATÓRIO");
P("O relatório segue o roteiro da disciplina, dividido em Parte 1 (Modelagem) e Parte 2 (Implementação). Para atender à NBR 14724, a introdução e as considerações finais foram acrescentadas e as referências ocupam a posição pós-textual, sem indicativo numérico. O Quadro 2 mostra onde está cada item do roteiro.");
quadro("Correspondência entre o roteiro da disciplina e as seções do relatório", ["Item do roteiro", "Seção"], [
  ["1 – Enunciado do projeto baseado em microsserviços", "1.1"],
  ["Parte 1 – Modelagem: 2 – Metodologia ágil utilizada", "2"],
  ["3 – Técnicas de reuso de software utilizadas", "3"],
  ["4 – Desenvolvimento segundo a metodologia ágil e as técnicas de reuso", "4"],
  ["5 – Product Backlog e Sprint Backlog de cada sprint", "5"],
  ["6 – Arquitetura (6.1 arquitetura; 6.2 API Gateway; 6.3 microsserviços e componentes; 6.4 sistema de recomendação; 6.5 tela dos microsserviços em execução)", "6 (6.1 a 6.5)"],
  ["Parte 2 – Implementação: 7 – Tecnologias, linguagem e banco de dados por microsserviço", "7"],
  ["8 – Telas do funcionamento, destacando os microsserviços", "8"],
  ["9 – Código no GitHub e instruções de execução (link também na capa)", "9 e capa"],
  ["10 – Referências bibliográficas", "REFERÊNCIAS"],
  ["11 – Vídeo do jogo (link também na capa)", "10 e capa"],
], [7.5, 2.5]);

// ---------------------------------------------------------------- 2 Scrum
H1("2 METODOLOGIA ÁGIL UTILIZADA: SCRUM");
P("A equipe usou o **Scrum**, um framework leve para gerar valor por meio de soluções adaptativas, organizado em sprints de duração fixa, com papéis, eventos e artefatos definidos (SCHWABER; SUTHERLAND, 2020). Como sugere Sommerville (2018), o método foi adaptado ao contexto: uma equipe de dois desenvolvedores. O trabalho foi organizado em um Product Backlog de histórias de usuário priorizadas e executado em **seis sprints**, cada uma com uma meta e um Sprint Backlog próprio; o incremento de cada sprint é um jogo executável, com os testes automatizados passando. O Quadro 3 resume como cada elemento do Scrum foi aplicado.");
quadro("Elementos do Scrum no projeto", ["Elemento do Scrum", "Como foi aplicado no projeto"], [
  ["Papéis", "Em uma equipe de dois, os papéis de Product Owner (prioriza o backlog com base no enunciado da disciplina) e de Scrum Master (remove impedimentos, como toolchain, implantação e CI) foram exercidos pelos próprios integrantes; ambos atuam como desenvolvedores."],
  ["Product Backlog", "Histórias de usuário com prioridade, derivadas do enunciado (jogo, não violência, microsserviços, componentes, recomendação) e do retorno de cada revisão (seção 5)."],
  ["Sprint Planning", "No início de cada sprint, a meta e os itens escolhidos foram registrados em um plano (GODOT_3D_PLAN.md e os marcos 0 a 6 de ARCHITECTURE_ONLINE.md)."],
  ["Daily Scrum", "Acompanhamento assíncrono pelo histórico de commits e pelas mensagens da equipe."],
  ["Sprint Review", "Demonstração do incremento: partida jogada de ponta a ponta, incluindo os testes e2e no navegador e o roteiro docs/demo.md."],
  ["Sprint Retrospective", "As lições viraram itens de backlog, por exemplo extrair componentes antes de levar o jogo para o online e cobrir cada falha corrigida com um teste."],
  ["Definição de Pronto", "Código revisado, testes automatizados passando no CI (GitHub Actions), documentação atualizada e o fluxo funcionando no stack Docker."],
  ["Incremento", "Ao fim de cada sprint, um build jogável: protótipo C++, jogo 3D, regras completas, online, navegador e IA online, recomendação."],
], [2.4, 7.6]);

// ---------------------------------------------------------------- 3 Reuso
H1("3 TÉCNICAS DE REUSO DE SOFTWARE UTILIZADAS");
P("As técnicas de reuso adotadas foram **microsserviços** e **componentes de software**. Sommerville (2018) e Pressman e Maxim (2021) apresentam o reuso como um espectro que vai de objetos e componentes a sistemas inteiros e frameworks; o projeto usa vários desses níveis. Nos microsserviços, cada serviço é reutilizado por qualquer cliente através do seu contrato, sem compartilhar banco de dados, como no padrão *database per service* (RICHARDSON, 2018). Nos componentes, o mesmo módulo é composto por adaptadores diferentes, e alguns padrões de projeto aparecem de forma explícita, como o *Adapter* (os adaptadores offline e online da partida) e o *Strategy* (as fontes de entrada intercambiáveis: teclado, rede e bot) (GAMMA et al., 2000). O Quadro 4 detalha o que é reutilizado em cada técnica.");
quadro("Técnicas de reuso", ["Técnica", "O que é reutilizado", "Benefício obtido"], [
  ["Microsserviços", "Serviços independentes (lobby, match runtime, results, ai-bot e recommendation) reutilizados por qualquer cliente através de contratos HTTP/WebSocket versionados; o recommendation reutiliza a API pública do results em vez de acessar o banco dele.", "Implantação, escala e falha isoladas: com o ai-bot fora, só o modo contra IA online para; com o recommendation fora, só o painel de recomendação some."],
  ["Componentes de software", "MatchSession + MatchConfig (offline, servidor, bot e benchmark); NetProtocol (navegador, desktop, servidor e bot); MatchToken = credentials.py (a mesma credencial em duas linguagens); Tactics (IA interna e bot); ControlServer (API do runtime, API do bot e serviço falso nos testes); LobbyClient e ServiceStatusPanel (menus).", "Uma única regra de partida em todo lugar: offline e online executam o mesmo MatchSession.step."],
  ["Reuso de frameworks e COTS", "Godot 4.7 (motor), FastAPI e Uvicorn, psycopg, Caddy (gateway com TLS automático), PostgreSQL, Docker Compose, Playwright e pytest.", "Esforço concentrado nas regras do jogo e nos contratos entre os serviços."],
  ["Reuso de ativos", "Modelos GLB de jogadores e da bola, animações e áudio.", "Visual realista sem modelagem 3D própria."],
], [2.2, 5.3, 3.5]);

// ---------------------------------------------------------------- 4 Desenvolvimento
H1("4 DESENVOLVIMENTO SEGUNDO O SCRUM E AS TÉCNICAS DE REUSO");
P("O histórico do repositório (108 commits entre abril e outubro de 2026) mostra a evolução em seis sprints. Em cada uma, a técnica de reuso foi aplicada de forma incremental, como descrevem as subseções a seguir.");
const sprintsNarr = [
  ["4.1 SPRINT 1 (14 A 17/04/2026): PROTÓTIPO EM C++/OPENGL", "Foram construídos o campo, os jogadores, a física da bola, a IA, o HUD com barra de força, as animações, o áudio e os chutes especiais. O jogo foi dividido em módulos (game_logic, player, ball), já preparando o reuso. Esse protótipo continua no repositório como referência (src/, include/)."],
  ["4.2 SPRINT 2 (12 A 16/06/2026): JOGO 3D NO GODOT COM ARQUITETURA MODULAR", "Foram feitos o estádio noturno, os menus, as configurações, a troca de jogador e o HUD. Nesta sprint ocorreu a primeira grande aplicação de **componentes**: o controlador monolítico foi dividido em GameConfig, classes de dados, construtores de cena e sistemas (AudioManager, SettingsStore, MenuManager, InputReader, AIController, MatchSimulation, MatchView), e o controlador passou a ser apenas um orquestrador."],
  ["4.3 SPRINT 3 (19/06 A 07/07/2026): REGRAS COMPLETAS E REALISMO", "Entraram o voo da bola, os reinícios (lateral, escanteio, tiro de meta), as faltas e o impedimento, as estatísticas, uma IA mais inteligente e um polimento visual. Toda a aleatoriedade passou a vir de um gerador com semente (sim.rng), requisito para reutilizar a simulação no servidor."],
  ["4.4 SPRINT 4 (05/10/2026): BASE ONLINE COM MICROSSERVIÇOS", "Esta sprint cobriu os marcos 0 a 3: extração do componente **MatchSession + MatchConfig**; *spike* de implantação (inicialização por papel e export headless); fatia vertical online (protocolo binário, salas autoritativas e cliente online). Os **microsserviços** lobby (salas e credenciais assinadas) e results (histórico e ranking) foram criados junto com o Docker Compose e o primeiro teste e2e no navegador."],
  ["4.5 SPRINT 5 (20/10/2026): NAVEGADOR, IA ONLINE E DOCUMENTAÇÃO", "Esta sprint cobriu os marcos 4 a 6: tier gráfico para a web, menu Play Online, limites configuráveis no gateway e CI no GitHub Actions. O componente **Tactics** foi extraído para ser compartilhado pela IA interna e pelo novo microsserviço **ai-bot**, e o lobby passou a criar salas contra a IA. Fecharam a sprint o documento de arquitetura, o roteiro de demonstração e as correções de robustez (concorrência no lobby, congestionamento no runtime, casos de saída do cliente)."],
  ["4.6 SPRINT 6 (28 E 29/10/2026): SISTEMA DE RECOMENDAÇÃO E ENTREGA", "Foram entregues o novo microsserviço **recommendation** (motor Elo, modelo de leitura e API, com 29 testes), as rotas no gateway, o status dos microsserviços (`/api/status/v1/*`), o componente **ServiceStatusPanel** no menu principal e no Play Online (destacando os serviços usados por cada ação), o painel “Recommended for you”, as capturas de tela automatizadas e este relatório."],
];
sprintsNarr.forEach(([t, d]) => { H2(t); P(d); });

// ---------------------------------------------------------------- 5 Backlogs
H1("5 PRODUCT BACKLOG E SPRINT BACKLOGS");
P("O Product Backlog reúne as histórias de usuário do produto, ordenadas por prioridade; cada Sprint Backlog reúne a meta da sprint e as tarefas escolhidas para atingi-la (SCHWABER; SUTHERLAND, 2020).");
H2("5.1 PRODUCT BACKLOG");
P("O Quadro 5 apresenta o Product Backlog com a prioridade, a sprint em que cada item foi realizado e a situação atual. Os itens PB19 a PB21 permanecem como backlog futuro.");
quadro("Product Backlog", ["ID", "História de usuário", "Prior.", "Sprint", "Situação"], [
  ["PB01", "Como jogador, quero jogar uma partida de futebol 11x11 contra a IA.", "Alta", "1, 2", "Concluído"],
  ["PB02", "Como jogador, quero controlar meu time com teclado e mouse ou controle (passe, chute com carga, desarme, troca e sprint).", "Alta", "1, 2", "Concluído"],
  ["PB03", "Como jogador, quero um estádio 3D realista (iluminação noturna, torcida, gramado).", "Média", "2, 3", "Concluído"],
  ["PB04", "Como jogador, quero menus, configurações e escolher o lado de cada dispositivo.", "Média", "2", "Concluído"],
  ["PB05", "Como jogador, quero regras de futebol: laterais, escanteios, faltas, impedimento e estatísticas.", "Alta", "3", "Concluído"],
  ["PB06", "Como jogador, quero chutes especiais com câmera lenta, sem violência.", "Média", "1, 2", "Concluído"],
  ["PB07", "Como jogador, quero uma IA adversária com níveis de dificuldade.", "Alta", "1, 3", "Concluído"],
  ["PB08", "Como desenvolvedor, quero a regra da partida em um componente reutilizável (MatchSession/MatchConfig).", "Alta", "4", "Concluído"],
  ["PB09", "Como jogador, quero jogar online contra um amigo usando um código de sala.", "Alta", "4", "Concluído"],
  ["PB10", "Como jogador, quero partidas online justas (servidor autoritativo, credenciais assinadas).", "Alta", "4", "Concluído"],
  ["PB11", "Como jogador, quero ver o histórico de partidas e o ranking.", "Média", "4", "Concluído"],
  ["PB12", "Como jogador, quero jogar no navegador sem instalar nada.", "Alta", "5", "Concluído"],
  ["PB13", "Como jogador, quero jogar online contra a IA.", "Média", "5", "Concluído"],
  ["PB14", "Como equipe, quero integração contínua rodando todos os testes e o fluxo no navegador.", "Média", "5", "Concluído"],
  ["PB15", "Como avaliador, quero a documentação da arquitetura e um roteiro de demonstração.", "Média", "5", "Concluído"],
  ["PB16", "Como jogador, quero recomendações de nível de IA e de rivais do meu nível.", "Alta", "6", "Concluído"],
  ["PB17", "Como avaliador, quero ver na interface quais microsserviços estão rodando e quais cada ação usa.", "Alta", "6", "Concluído"],
  ["PB18", "Como equipe, quero entregar o relatório final e o vídeo de demonstração.", "Alta", "6", "Relatório pronto; vídeo a gravar"],
  ["PB19", "Como jogador, quero uma conta com login para manter o ranking entre dispositivos.", "Baixa", "–", "Backlog futuro"],
  ["PB20", "Como jogador, quero matchmaking automático com rivais recomendados.", "Baixa", "–", "Backlog futuro"],
  ["PB21", "Como operador, quero várias instâncias do match runtime com roteamento de salas.", "Baixa", "–", "Backlog futuro"],
], [0.9, 6.2, 0.9, 0.9, 1.6]);
H2("5.2 SPRINT BACKLOGS");
P("Os quadros a seguir trazem o Sprint Backlog de cada sprint, com as tarefas, o item do Product Backlog atendido e a situação.");
const sb = [
  ["5.2.1 Sprint 1 (14 a 17/04/2026)", "protótipo jogável em C++/OpenGL", [
    ["Campo, placar, estádio, física da bola e dos jogadores", "PB01", "Concluído"],
    ["Barra de força do chute, mira pelo cursor, HUD", "PB02", "Concluído"],
    ["IA dos jogadores (sem sair do campo)", "PB07", "Concluído"],
    ["Sprites, animações, goleiros por time", "PB03", "Concluído"],
    ["Música, sons de chute, apito do árbitro", "PB03", "Concluído"],
    ["Hissatsu (chute especial) e partículas", "PB06", "Concluído"],
    ["Modularização do game loop e documentação técnica", "PB08", "Concluído"]]],
  ["5.2.2 Sprint 2 (12 a 16/06/2026)", "jogo 3D no Godot com arquitetura modular", [
    ["Projeto Godot 3D, câmera, iluminação", "PB01", "Concluído"],
    ["Estádio noturno, alambrado, placas, redes, marcações", "PB03", "Concluído"],
    ["Menu principal, modos, configurações, áudio, relógio", "PB04", "Concluído"],
    ["Extrair GameConfig, dados, construtores e sistemas (controlador orquestrador)", "PB08", "Concluído"],
    ["Troca de jogador estilo FIFA, sprint, controle travado no portador", "PB02", "Concluído"],
    ["Atribuição de dispositivos antes da partida (2 controles)", "PB04", "Concluído"],
    ["HUD estilo transmissão, bola Trionda, rastro no gramado", "PB03", "Concluído"],
    ["Chutes especiais com câmera lenta, auras e comemoração", "PB06", "Concluído"]]],
  ["5.2.3 Sprint 3 (19/06 a 07/07/2026)", "regras completas e realismo", [
    ["Voo da bola (altura, quique, efeito) e reinícios", "PB05", "Concluído"],
    ["Desarme, sprint com fôlego, goleiro com reação por dificuldade", "PB02, PB07", "Concluído"],
    ["Faltas, impedimento e estatísticas da partida", "PB05", "Concluído"],
    ["IA: intervalos de decisão, infiltrações, marcação", "PB07", "Concluído"],
    ["Polimento visual: neblina, luz, grama", "PB03", "Concluído"]]],
  ["5.2.4 Sprint 4 (05/10/2026)", "base online com microsserviços (marcos 0 a 3)", [
    ["Extrair MatchSession/MatchConfig como componente", "PB08", "Concluído"],
    ["Spike de implantação: inicialização por papel, export headless", "PB10", "Concluído"],
    ["Fatia vertical: protocolo v1, salas autoritativas, cliente online", "PB09, PB10", "Concluído"],
    ["Credenciais assinadas (HMAC), API de controle do runtime", "PB10", "Concluído"],
    ["Microsserviço lobby (salas, convidados, reservas)", "PB09", "Concluído"],
    ["Microsserviço results (ingestão idempotente, ranking)", "PB11", "Concluído"],
    ["Docker Compose com gateway e PostgreSQL; e2e lobby → results", "PB09, PB11", "Concluído"]]],
  ["5.2.5 Sprint 5 (20/10/2026)", "jogo no navegador, IA online e documentação (marcos 4 a 6)", [
    ["Tier gráfico Compatibility para a web", "PB12", "Concluído"],
    ["Menu Play Online e LobbyClient", "PB09, PB12", "Concluído"],
    ["Limites configuráveis do runtime e do gateway", "PB12", "Concluído"],
    ["CI no GitHub Actions (Godot, pytest, exports, e2e)", "PB14", "Concluído"],
    ["Extrair Tactics; microsserviço ai-bot (BotBrain)", "PB13", "Concluído"],
    ["Salas contra IA no lobby; Play vs AI (online) no menu", "PB13", "Concluído"],
    ["ARCHITECTURE_ONLINE.md e roteiro de demonstração", "PB15", "Concluído"],
    ["Correções de robustez (concorrência, congestionamento, saída do cliente)", "PB10", "Concluído"]]],
  ["5.2.6 Sprint 6 (28 e 29/10/2026)", "sistema de recomendação, visibilidade dos microsserviços e entrega", [
    ["Microsserviço recommendation: motor Elo, modelo de leitura, API", "PB16", "Concluído"],
    ["29 testes pytest do recommendation; entrada no CI", "PB16, PB14", "Concluído"],
    ["Gateway: /api/recommendations/v1 e /api/status/v1/<serviço>", "PB16, PB17", "Concluído"],
    ["Componente ServiceStatusPanel (menu principal e Play Online)", "PB17", "Concluído"],
    ["Painel “Recommended for you” e “Use this AI level”", "PB16", "Concluído"],
    ["Testes GDScript do cliente; capturas de tela automatizadas (e2e)", "PB14, PB18", "Concluído"],
    ["Relatório final", "PB18", "Concluído"],
    ["Vídeo de demonstração", "PB18", "A fazer"]]],
];
sb.forEach(([title, goal, items]) => {
  H3(title);
  P(`Meta da sprint: ${goal}.`);
  quadro(`Sprint Backlog da ${title.replace(/^[\d.]+ /, "").replace(/ \(.*/, "")}`, ["Tarefa", "Item", "Situação"], items, [6.6, 1.6, 1.6]);
});

// ---------------------------------------------------------------- 6 Arquitetura
H1("6 ARQUITETURA DO SISTEMA DE MICROSSERVIÇOS");
P("Esta seção apresenta a arquitetura (6.1), o API Gateway (6.2), a especificação de cada microsserviço e componente (6.3), o sistema de recomendação (6.4) e a listagem dos microsserviços em execução (6.5).");
H2("6.1 ARQUITETURA DO SISTEMA UTILIZANDO MICROSSERVIÇOS");
P("Todo o sistema sobe com um único `docker compose up` (projeto `inazuma-online`). O **gateway** é o único contêiner com portas publicadas e o único na rede `public`, seguindo o padrão *API Gateway* (RICHARDSON, 2018). Os demais ficam só na rede `internal`, declarada `internal: true` e portanto sem rota para fora. Cada microsserviço tem processo, imagem, configuração, testes, health check e dados próprios, e se comunica com os outros apenas por contratos HTTP/WebSocket versionados (Figura 1).");
figure(IMG("fig_arch.png"), "Arquitetura de microsserviços do Inazuma Eleven GL", FONTE_AUTORES, 16, 10);
P("O Quadro 12 resume a responsabilidade, as interfaces e os dados de cada serviço.");
quadro("Serviços do sistema", ["Serviço", "Responsabilidade", "Interfaces", "Dados"], [
  ["gateway (infra)", "Ponto único de entrada: TLS, arquivos do jogo web, roteamento e status dos serviços", "público :8080/:8443", "certificados (volume)"],
  ["lobby", "Salas com código de 6 letras, jogadores convidados, reservas, credenciais assinadas; provisiona a partida no runtime", "/api/lobby/v1/* (público); chama o runtime e o ai-bot", "PostgreSQL, banco lobby"],
  ["match runtime", "Executa as partidas autoritativas (Godot headless), valida credenciais, mantém o registro de partidas encerradas e o spool de resultados", "WebSocket /ws/game/<id>; API interna :8911", "memória e arquivos no volume runtime-data"],
  ["results", "Histórico de partidas e ranking; ingestão idempotente", "/api/stats/v1/* (público); POST interno", "PostgreSQL, banco results"],
  ["ai-bot (opcional)", "Adversário de IA online, que joga pelo mesmo protocolo de um navegador", "API interna de jobs :8920", "memória"],
  ["recommendation (opcional)", "Sistema de recomendação: Elo, nível de IA e rivais", "/api/recommendations/v1/* (público)", "modelo em memória, derivado da API do results"],
  ["postgres (infra)", "Um servidor com dois bancos e dois papéis (lobby, results)", "interno :5432", "volume postgres-data"],
], [2, 4.3, 2.4, 2.2]);
P("**Isolamento de falhas.** Com o results fora, as partidas continuam e os resultados ficam no spool do runtime até serem entregues. Com o ai-bot fora, só a criação de salas contra IA falha (503 `bot_unavailable`) e o PvP continua. Com o recommendation fora, o jogo apenas esconde o painel de recomendação. Esses cenários são verificados por `tests/e2e/run_failure_checks.sh` e `run_bot_checks.sh`.");

H2("6.2 API GATEWAY (CÓDIGO DOCUMENTADO)");
P("O gateway é o **Caddy 2.10** (CADDY, 2026), configurado por um único Caddyfile. Ele serve o build web do jogo, encaminha cada prefixo público ao microsserviço correspondente (removendo o prefixo), faz o upgrade de WebSocket para o runtime e nunca expõe as APIs internas: qualquer outro `/api/*` responde 404. A partir da Sprint 6, também responde `/api/status/v1/<serviço>` consultando o `/health` interno de cada microsserviço; desse health só sai “up” ou “down”, e o corpo interno nunca é repassado. O Quadro 13 lista as rotas; os Códigos 1 e 2 trazem a configuração completa.");
quadro("Rotas do API Gateway", ["Rota pública", "Destino", "Observação"], [
  ["/api/lobby/v1/*", "lobby:8000", "prefixo /api/lobby removido"],
  ["/api/stats/v1/*", "results:8000", "prefixo /api/stats removido"],
  ["/api/recommendations/v1/*", "recommendation:8000", "prefixo /api/recommendations removido"],
  ["/api/status/v1/<serviço>", "/health do serviço", "200 {\"status\":\"up\"} ou 503 {\"status\":\"down\"}"],
  ["/ws/game/<match_id>", "match-runtime:8910", "WebSocket do jogador"],
  ["/api/* (demais)", "404", "APIs internas nunca são roteadas"],
  ["/healthz", "200 ok", "liveness do gateway"],
  ["demais caminhos", "/srv/web", "build web do Godot"],
], [3.2, 2.8, 4]);
code(rd("services/gateway/Caddyfile"), "Configuração do API Gateway (services/gateway/Caddyfile)");
code(between("docker-compose.yml", /^  gateway:/, /^  match-runtime:/), "Serviço gateway no docker-compose.yml");

H2("6.3 ESPECIFICAÇÃO DE CADA MICROSSERVIÇO E COMPONENTE DE SOFTWARE");
P("Para cada microsserviço são apresentados a linguagem, os dados, a responsabilidade e o código documentado; em seguida, os componentes de software reutilizados.");
H3("6.3.1 Microsserviço lobby");
P("**Linguagem:** Python 3.12 (FastAPI, psycopg 3). **Banco:** PostgreSQL, banco `lobby`. **Responsabilidade:** criar salas e entrar nelas, emitir identidades de convidado e credenciais assinadas, e provisionar a partida no runtime *antes* de entregar a credencial. As operações são idempotentes por `request_id`, e o status é reconciliado com o runtime (Quadro 14 e Códigos 3 e 4).");
quadro("API do lobby", ["Método e rota", "Descrição", "Respostas"], [
  ["POST /api/lobby/v1/rooms", "Cria sala PvP ou contra IA ({nickname, half_length_s, request_id, mode?, difficulty?})", "201 com código, match_id, token, ws_url; 503 runtime ou bot indisponível"],
  ["POST /api/lobby/v1/rooms/{code}/join", "Entra na sala com o código", "200 com credencial; 404; 409 sala cheia ou fechada"],
  ["GET /api/lobby/v1/rooms/{code}", "Status da sala (reconciliado com o runtime)", "200; 404"],
  ["GET /health", "Saúde (executa SELECT 1)", "200 ou 503"],
], [3.6, 4, 3.4]);
code(pyDoc("services/lobby/app/main.py"), "Especificação da API do lobby (services/lobby/app/main.py)");
code(between("services/lobby/app/main.py", /@app\.get\("\/health"\)/, /^    return app/), "Rotas do lobby (services/lobby/app/main.py)");
H3("6.3.2 Microsserviço match runtime");
P("**Linguagem:** GDScript (Godot 4.7.2 headless, export Linux Server). **Dados:** partidas vivas em memória; registro de partidas encerradas e spool de resultados em arquivos JSON no volume `runtime-data`. **Responsabilidade:** executar as partidas de forma autoritativa (estados WAITING → RUNNING ⇄ PAUSED → FINISHED), validar a credencial no HELLO, receber as entradas dos jogadores, enviar snapshots e eventos e entregar o resultado ao results. Os clientes exibem o estado com cerca de 100 ms de atraso, interpolando entre snapshots, técnica clássica de jogos cliente-servidor (BERNIER, 2001). Os Códigos 5 e 6 trazem a especificação.");
code(gdHeader("scripts/server/runtime_control_api.gd"), "API de controle do runtime (scripts/server/runtime_control_api.gd)");
code(gdHeader("scripts/server/match_room.gd"), "Uma partida no runtime (scripts/server/match_room.gd)");
H3("6.3.3 Microsserviço results");
P("**Linguagem:** Python 3.12 (FastAPI, psycopg 3). **Banco:** PostgreSQL, banco `results` (tabelas `matches` e `match_players`). **Responsabilidade:** registrar cada resultado de forma idempotente (o mesmo documento devolve 200; um documento conflitante, 409) e servir o histórico e o ranking (vitória 3, empate 1, derrota 0; desempate por saldo e gols pró). O Código 7 traz a API completa.");
code(rd("services/results/app/main.py"), "API do results (services/results/app/main.py)");
H3("6.3.4 Microsserviço ai-bot");
P("**Linguagem:** GDScript (Godot headless, o mesmo export do runtime, iniciado com `--bot`). **Dados:** apenas memória. **Responsabilidade:** hospedar bots que entram na partida como um jogador remoto, observam o snapshot mais recente e decidem a cada intervalo de reação (chutar, passar, driblar, marcar, desarmar). O lobby envia o job; o bot nunca acessa o runtime por fora do protocolo (Códigos 8 e 9).");
code(gdHeader("scripts/bot/bot_job_api.gd"), "API de jobs do ai-bot (scripts/bot/bot_job_api.gd)");
code(gdHeader("scripts/bot/bot_brain.gd"), "Política de decisão do bot (scripts/bot/bot_brain.gd)");
H3("6.3.5 Microsserviço recommendation");
P("Especificado na seção 6.4, que trata do sistema de recomendação.");
H3("6.3.6 Componentes de software");
P("Um componente, aqui, é um módulo com interface pequena e documentada, dono do próprio estado, usado por mais de um adaptador (SZYPERSKI, 2002). Ser componente não exige um contêiner próprio. A Figura 2 mostra quem reutiliza cada componente, e o Quadro 15 resume as interfaces; o cabeçalho de cada arquivo (Códigos 10 a 17) é a especificação detalhada.");
figure(IMG("fig_comp.png"), "Componentes de software e os adaptadores que os reutilizam", FONTE_AUTORES, 16, 9.5);
quadro("Componentes de software", ["Componente", "Interface", "Reutilizado por"], [
  ["MatchSession + MatchConfig", "initialize(config, seed), submit_input, step, read_state, drain_events; MatchConfig.to_dict/from_dict", "jogo offline, MatchRoom (runtime), BotSession (espelho), benchmark de força do bot"],
  ["NetProtocol v1", "encode_* / decode (rejeita mensagens malformadas)", "navegador, desktop, runtime, ai-bot"],
  ["MatchToken = credentials.py", "sign / verify; formato binário fixo + HMAC-SHA256", "lobby (Python) e runtime (GDScript), com vetores de teste comuns"],
  ["Tactics", "consultas táticas puras (passe, drible, chute, marcação)", "AIController (IA interna) e BotBrain (ai-bot)"],
  ["ControlServer", "listen, poll, handler(method, path, headers, body)", "API de controle do runtime, API de jobs do bot, serviços falsos nos testes"],
  ["LobbyClient", "corrotinas create_room, join_room, recommendations e outras", "menu Play Online (duas instâncias: ações e leituras)"],
  ["ServiceStatusPanel", "probe(), highlight(ids), layouts completo e compacto", "menu principal e páginas do Play Online"],
], [2.6, 4.2, 4.2]);
code(gdHeader("scripts/match/match_session.gd"), "Componente MatchSession (scripts/match/match_session.gd)");
code(gdHeader("scripts/match/match_config.gd"), "Componente MatchConfig (scripts/match/match_config.gd)");
code(gdHeader("scripts/net/protocol.gd"), "Componente NetProtocol (scripts/net/protocol.gd)");
code(gdHeader("scripts/net/match_token.gd"), "Componente MatchToken (scripts/net/match_token.gd)");
code(gdHeader("scripts/ai/tactics.gd"), "Componente Tactics (scripts/ai/tactics.gd)");
code(gdHeader("scripts/server/control_server.gd"), "Componente ControlServer (scripts/server/control_server.gd)");
code(gdHeader("scripts/net/lobby_client.gd"), "Componente LobbyClient (scripts/net/lobby_client.gd)");
code(rd("scripts/systems/service_status_panel.gd"), "Componente ServiceStatusPanel (scripts/systems/service_status_panel.gd)");

// ---------------------------------------------------------------- 6.4
H2("6.4 SISTEMA DE RECOMENDAÇÃO (ESPECIFICAÇÃO E CÓDIGO DOCUMENTADO)");
P("**Objetivo.** Recomendar a cada jogador o **nível da IA online** que oferece um desafio adequado e **rivais humanos do mesmo nível**, a partir do desempenho real registrado no histórico de partidas.");
P("**Abordagem.** Trata-se de uma recomendação baseada em conhecimento sobre um modelo de habilidade. Cada jogador recebe um **rating Elo** (ELO, 1978), na variante para futebol do World Football Elo Ratings (2026), que pondera o resultado pelo saldo de gols. Os três bots (Easy, Normal e Hard) também são avaliados como jogadores: começam com ratings iniciais ordenados pela força medida (docs/measurements.md) e são reavaliados pelos resultados reais. O nível recomendado é o do bot contra o qual o jogador tem **expectativa de pontuação mais próxima de 60%**, um desafio que ele tende a vencer sem que seja fácil, em linha com o ajuste dinâmico de dificuldade (HUNICKE, 2005) e com o estado de *flow* descrito por Csikszentmihalyi (1990). Os rivais são os três humanos com rating mais próximo. A Figura 3 mostra o fluxo de dados, e o Quadro 16, os parâmetros do modelo.");
figure(IMG("fig_rec.png"), "Fluxo de dados do sistema de recomendação", FONTE_AUTORES, 16, 6);
quadro("Parâmetros do modelo de recomendação", ["Parâmetro", "Valor", "Justificativa"], [
  ["Rating inicial do jogador", "1000", "convenção do Elo"],
  ["Rating inicial dos bots", "Easy 900, Normal 1050, Hard 1200", "o bot mais forte vence todas as partidas decididas entre bots (docs/measurements.md)"],
  ["K", "40 nas 10 primeiras partidas, depois 24", "converge rápido para novatos e estabiliza depois"],
  ["Índice de saldo G", "1 (0 ou 1 gol), 1,5 (2), (11 + N)/8 (N ≥ 3)", "World Football Elo Ratings (2026)"],
  ["Alvo de expectativa", "0,6", "desafio vencível; em empate, vence o nível mais fácil"],
  ["Histórico considerado", "as 5000 partidas contadas mais recentes", "custo limitado de recomputação"],
  ["Atualização", "incremental a cada 10 s; completa a cada 5 min", "reflete partidas novas e entregas atrasadas do spool"],
], [2.8, 3.6, 4.6]);
P("**Arquitetura do serviço.** O recommendation **não tem banco próprio e não lê o banco de outro serviço**: ele consome a API pública `GET /v1/matches/recent` do results e mantém em memória um modelo de leitura derivado. Se o results cair, o serviço continua respondendo com o último modelo, marcado como `stale`; antes da primeira leitura bem-sucedida, responde 503 `results_unavailable`. O Quadro 17 lista a API, e o Código 18 mostra uma resposta real.");
quadro("API do recommendation", ["Rota (via gateway)", "Resposta"], [
  ["GET /api/recommendations/v1/recommendations?player_id=<uuid>", "{player: rating, partidas, V-E-D, forma; ai_level: nível, probabilidade, motivo, opções; rivals: até 3; model: estado do modelo}; 400 invalid_player_id; 503 results_unavailable"],
  ["GET /api/recommendations/v1/ratings?limit=", "ranking Elo (bots incluídos)"],
  ["GET /health (interno)", "200 com o estado do modelo"],
], [4.2, 6.8]);
code(`$ curl -s localhost:8080/api/recommendations/v1/recommendations
{"player":{"player_id":null,"nickname":null,"rating":1000,"played":0,"wins":0,"draws":0,
 "losses":0,"form":"","provisional":true},
 "ai_level":{"level":"easy","win_probability":0.64,"reason":"first_match",
  "options":[{"level":"easy","bot_rating":900,"win_probability":0.64},
             {"level":"normal","bot_rating":1050,"win_probability":0.429},
             {"level":"hard","bot_rating":1200,"win_probability":0.24}]},
 "rivals":[],"model":{"matches":0,"players":3,"stale":false,"updated_at":"2026-10-29T11:36:51Z"}}`,
  "Resposta real do recommendation para um jogador novo", FONTE_AUTORES);
P("**Testes.** São 29 testes pytest (`services/recommendation/tests/`) que cobrem a simetria da expectativa, o índice de saldo, a soma zero entre novatos, o K provisório, os ratings iniciais dos bots, a recomendação para novatos, a subida e a descida do nível com sequências de vitórias e derrotas, rivais sem o próprio jogador e sem bots, a validação de id, partidas não contadas ignoradas, o modelo antigo servido com o results fora, a limitação de atualização, a paginação, a sincronização completa que encontra um resultado atrasado e o limite do histórico. Os Códigos 19 a 23 trazem o código documentado do serviço e do painel no jogo.");
code(rd("services/recommendation/app/engine.py"), "Algoritmo de recomendação (services/recommendation/app/engine.py)");
code(rd("services/recommendation/app/model.py"), "Modelo de leitura (services/recommendation/app/model.py)");
code(rd("services/recommendation/app/main.py"), "API do recommendation (services/recommendation/app/main.py)");
code(rd("services/recommendation/app/bots.py"), "Identidades dos bots (services/recommendation/app/bots.py)");
code(between("scripts/systems/online_menu.gd", /^func _load_recommendations/, /^func _on_use_level/), "Painel “Recommended for you” no jogo (scripts/systems/online_menu.gd)");

// ---------------------------------------------------------------- 6.5
H2("6.5 TELA COM A LISTAGEM DOS MICROSSERVIÇOS EM EXECUÇÃO");
P("A Figura 4 mostra a saída real de `docker compose ps` com todos os contêineres em execução e saudáveis (*healthy*), seguida da consulta de status de cada microsserviço pelo gateway.");
figure(IMG("fig_compose_ps.png"), "Microsserviços em execução (docker compose ps) e status pelo gateway", FONTE_TELA, 16, 9);
P("A mesma informação aparece **dentro do jogo**: o menu principal tem uma faixa “Online microservices”, e a tela Play Online tem o painel **MICROSERVICES**, com um indicador verde ou vermelho por serviço, atualizado a cada 5 segundos (Figura 5).");
figure(IMG("04_online_home.png"), "Painel MICROSERVICES (à direita) na tela Play Online, com os seis serviços no ar", FONTE_TELA, 16, 9);

// ---------------------------------------------------------------- 7 Tecnologias
H1("7 TECNOLOGIAS UTILIZADAS");
P("O Quadro 18 informa, para cada microsserviço, a linguagem de programação, o framework e o banco de dados utilizados. O jogo e os serviços headless usam o motor Godot (GODOT ENGINE, 2026); os serviços Python usam o FastAPI (FASTAPI, 2026); os bancos são PostgreSQL (POSTGRESQL GLOBAL DEVELOPMENT GROUP, 2026); o gateway é o Caddy (CADDY, 2026); e a implantação usa Docker Compose (DOCKER, 2026).");
quadro("Tecnologias por microsserviço", ["Microsserviço", "Linguagem", "Framework / runtime", "Banco de dados", "Comunicação"], [
  ["gateway (infra)", "Caddyfile (configuração)", "Caddy 2.10", "não (certificados em volume)", "HTTP/HTTPS, proxy WebSocket"],
  ["lobby", "Python 3.12", "FastAPI 0.115, Uvicorn, psycopg 3, httpx", "PostgreSQL 17 (banco lobby)", "REST/JSON"],
  ["match runtime", "GDScript", "Godot 4.7.2 headless", "não: JSON em volume (registro e spool)", "WebSocket binário (protocolo v1) e HTTP interno"],
  ["results", "Python 3.12", "FastAPI 0.115, psycopg 3", "PostgreSQL 17 (banco results)", "REST/JSON"],
  ["ai-bot", "GDScript", "Godot 4.7.2 headless", "não (memória)", "HTTP interno e WebSocket"],
  ["recommendation", "Python 3.12", "FastAPI 0.115, httpx", "não: modelo em memória derivado do results", "REST/JSON"],
  ["cliente (jogo)", "GDScript", "Godot 4.7 (WebAssembly e desktop)", "arquivo local de preferências", "HTTP e WebSocket via gateway"],
  ["postgres (infra)", "SQL", "PostgreSQL 17", "–", "–"],
], [2.2, 1.7, 2.8, 2.4, 2.3]);
P("As ferramentas de apoio são Docker e Docker Compose (implantação), GitHub Actions (CI), pytest (testes Python), suítes de teste headless em GDScript, Playwright (testes e2e e capturas de tela no navegador), Git e GitHub (versionamento).");

// ---------------------------------------------------------------- 8 Telas
H1("8 FUNCIONAMENTO DO SISTEMA PASSO A PASSO");
P("As capturas a seguir foram geradas pelo script `tests/e2e/report_screens.mjs`, que abre o build web real pelo gateway em um navegador headless, percorre os menus e verifica cada passo, com o mesmo mecanismo dos testes e2e. Em cada tela, o painel **MICROSERVICES** destaca em amarelo os serviços usados pela ação, e o Quadro 19, ao fim da seção, resume quais microsserviços cada tela usa.");
const screens = [
  ["01_main_menu.png", "MENU PRINCIPAL", "Menu principal", "O jogo abre no menu principal. A faixa inferior **Online microservices** mostra, ao vivo, os seis serviços do sistema (gateway, lobby, match runtime, ai-bot, results e recommendation) com o indicador verde de “no ar” e o total “6/6 online”, consultados pelo gateway em `/api/status/v1/*`."],
  ["02_match_setup.png", "PREPARAÇÃO DA PARTIDA OFFLINE", "Preparação da partida offline (Play Now)", "Em **Play Now**, cada dispositivo (teclado e mouse ou controles) escolhe um lado; um lado vazio fica com a IA. Na página seguinte escolhem-se a formação e as cores do uniforme. O modo offline não usa microsserviços: ele executa o componente MatchSession localmente."],
  ["03_offline_match.png", "PARTIDA OFFLINE", "Partida offline", "A partida em 3D tem estádio noturno, HUD com placar e relógio e o anel no jogador controlado. O mesmo componente MatchSession executa esta partida e, no servidor, as partidas online."],
  ["04_online_home.png", "PLAY ONLINE", "Tela Play Online", "A tela **Play Online** concentra os microsserviços. À esquerda, **Recommended for you** (microsserviço recommendation) mostra o rating Elo do jogador, o nível de IA recomendado com a expectativa de pontuação, o motivo e os rivais do mesmo nível. Ao centro ficam as ações: apelido, duração do tempo, criar sala, entrar com código, nível da IA e jogar contra a IA. À direita, o painel **MICROSERVICES** lista cada serviço com tecnologia, papel e status."],
  ["05_hover_vs_ai.png", "DESTAQUE DOS MICROSSERVIÇOS USADOS POR UMA AÇÃO", "Microsserviços destacados ao passar o mouse sobre Play vs AI", "Ao passar o mouse (ou o foco do controle) sobre **Play vs AI (online)**, o painel destaca em amarelo os serviços que a ação usa: API Gateway, Lobby, Match Runtime e AI Bot."],
  ["06_use_recommended_level.png", "APLICANDO A RECOMENDAÇÃO", "Nível de IA recomendado aplicado", "O botão **Use this AI level** seleciona o nível recomendado pelo serviço recommendation, e a linha de status confirma a escolha. Para essa ação o painel destaca Gateway, Recommendation e Results, de onde vem o histórico."],
  ["07_online_match_vs_ai.png", "PARTIDA ONLINE CONTRA A IA", "Partida online contra o ai-bot", "O lobby cria a sala contra a IA, provisiona a partida no match runtime e envia um job ao ai-bot, que entra como jogador remoto. O navegador recebe snapshots do runtime pelo WebSocket do gateway e os exibe com interpolação."],
  ["08_fulltime.png", "FIM DE JOGO", "Fim de jogo", "No apito final, o runtime grava o resultado no spool e o envia ao results; o jogo mostra o placar e as estatísticas (posse, finalizações, desarmes, faltas e outras) e oferece **New Online Match**."],
  ["09_online_home_after_match.png", "RECOMENDAÇÃO ATUALIZADA", "Recomendação atualizada após a partida", "De volta ao Play Online, o recommendation já incorporou a partida: o rating caiu de 1000 para 975 após a derrota, a forma mostra “L” e a expectativa contra o Easy baixou para 56%, então o motivo passa a ser ganhar confiança. Em “Rivals at your level” aparecem os jogadores humanos com rating mais próximo e a chance estimada contra cada um; nesta captura, são convidados criados em execuções anteriores do teste automatizado."],
  ["10_stats.png", "HISTÓRICO E RANKING", "Histórico de partidas e ranking", "**Recent Matches & Leaderboard** lê o microsserviço results: as partidas mais recentes e o ranking (3, 1 e 0 pontos). O painel destaca Gateway e Results."],
  ["11_waiting_room.png", "SALA PVP AGUARDANDO O ADVERSÁRIO", "Sala PvP aguardando o adversário", "**Create Room** pede ao lobby uma sala; o lobby provisiona a partida no runtime e devolve o código de seis caracteres para compartilhar. A partida começa quando o amigo entra com o código, e o painel destaca Gateway, Lobby e Match Runtime."],
];
screens.forEach(([f, heading, title, d], i) => {
  H2(`8.${i + 1} ${heading}`);
  P(`${d} (Figura ${6 + i}).`);
  figure(IMG(f), title, FONTE_TELA, 16, 9);
});
H2("8.12 MICROSSERVIÇOS UTILIZADOS POR TELA");
P("O Quadro 19 consolida os microsserviços utilizados em cada tela do sistema.");
quadro("Microsserviços usados por tela", ["Tela", "Microsserviços utilizados"], [
  ["Menu principal", "gateway (status de todos os serviços)"],
  ["Play Now (offline)", "nenhum (componente MatchSession local)"],
  ["Play Online – recomendação", "gateway, recommendation (que lê o results)"],
  ["Criar sala ou entrar com código", "gateway, lobby, match runtime (lobby → runtime)"],
  ["Play vs AI (online)", "gateway, lobby, match runtime, ai-bot"],
  ["Partida online", "gateway (WebSocket), match runtime"],
  ["Fim de jogo", "match runtime → results"],
  ["Recent Matches & Leaderboard", "gateway, results"],
], [4, 7]);

// ---------------------------------------------------------------- 9 GitHub
H1("9 CÓDIGO NO GITHUB E INSTRUÇÕES DE EXECUÇÃO");
children.push(new Paragraph({ alignment: AlignmentType.JUSTIFIED, indent: { firstLine: INDENT },
  spacing: { line: LINE_15, lineRule: AUTO, after: 0 },
  children: [new TextRun("Todo o código está no GitHub, em "),
    new ExternalHyperlink({ link: REPO_URL, children: [new TextRun({ text: REPO_URL, style: "Hyperlink" })] }),
    new TextRun(" (branch 3d-version), com as instruções completas no arquivo README.md. O link também consta na capa. As subseções a seguir resumem a execução.")] }));
H2("9.1 EXECUTAR O SISTEMA COMPLETO COM DOCKER");
P("Os pré-requisitos são o Docker Desktop (Windows ou macOS) ou o Docker Engine com Compose (Linux) e o Git. A execução segue estes passos:");
alineas([
  "clonar o repositório com `git clone " + REPO_URL + ".git` e entrar na pasta;",
  "criar o arquivo de segredos com `cp .env.example .env` (para uso local os valores de exemplo bastam; para publicar, gerar valores com `openssl rand -hex 32`);",
  "subir tudo com `docker compose up --build` (na primeira vez são compilados os exports do Godot e as imagens, o que leva alguns minutos);",
  "abrir `http://localhost:8080` no navegador e escolher Play Now (offline) ou Play Online;",
  "conferir os microsserviços com `docker compose ps` ou com `curl http://localhost:8080/api/status/v1/lobby` (o mesmo vale para cada serviço);",
  "encerrar com `docker compose down` (com `-v`, os dados também são apagados).",
]);
H2("9.2 EXECUTAR OS TESTES");
P("O Código 24 reúne os comandos dos testes. Todos rodam automaticamente no GitHub Actions (`.github/workflows/ci.yml`) a cada push, sem precisar de segredos.");
code(`# Python (cada serviço com PostgreSQL descartável; o recommendation usa um results falso)
docker compose -f services/docker-compose.test.yml run --rm --build lobby-tests
docker compose -f services/docker-compose.test.yml run --rm --build results-tests
docker compose -f services/docker-compose.test.yml run --rm --build recommendation-tests
docker compose -f services/docker-compose.test.yml down -v

# Godot (toolchain em Docker)
docker build -f tools/godot/Dockerfile --target godot -t inazuma/godot:4.7.2 tools/godot
docker run --rm -v "$PWD:/project" inazuma/godot:4.7.2 --headless --path /project --script res://tests/run_sim_tests.gd
#   ... run_net_tests.gd, run_runtime_tests.gd, run_bot_tests.gd, run_online_smoke.gd, run_scene_smoke.gd

# Navegador (com o stack no ar)
bash tests/e2e/run.sh online_menu.mjs        # dois navegadores jogam uma partida online completa
bash tests/e2e/run.sh report_screens.mjs out # gera as capturas deste relatório`, "Comandos para executar os testes");

// ---------------------------------------------------------------- 10 Vídeo
H1("10 VÍDEO DE DEMONSTRAÇÃO");
children.push(new Paragraph({ alignment: AlignmentType.JUSTIFIED, indent: { firstLine: INDENT },
  spacing: { line: LINE_15, lineRule: AUTO, after: 0 },
  children: [new TextRun("O vídeo de demonstração do jogo está disponível em "),
    new TextRun({ text: "[inserir link do vídeo – YouTube não listado ou Google Drive]", color: "C00000" }),
    new TextRun("; o link também consta na capa. O Quadro 20 apresenta o roteiro seguido, com cerca de cinco minutos, baseado em docs/demo.md.")] }));
quadro("Roteiro do vídeo", ["Tempo", "O que mostrar", "O que falar"], [
  ["0:00–0:30", "Capa e título; repositório no GitHub", "Tema: jogo não violento com microsserviços e componentes de software; integrantes."],
  ["0:30–1:00", "Terminal: `docker compose up -d` e `docker compose ps`", "Os seis serviços e o PostgreSQL saudáveis; só o gateway publica portas."],
  ["1:00–1:30", "Navegador em localhost:8080: menu principal", "A faixa de microsserviços ao vivo (6/6 online)."],
  ["1:30–2:15", "Play Now: uma jogada offline", "Regras de futebol, desarme só recupera a bola, falta por trás; o componente MatchSession."],
  ["2:15–3:00", "Play Online: painéis de recomendação e de microsserviços; passar o mouse nos botões", "Sistema de recomendação (Elo, nível de IA a 60%) e os serviços destacados por ação."],
  ["3:00–3:45", "Use this AI level → Play vs AI (online)", "Lobby → runtime → ai-bot; partida autoritativa no servidor."],
  ["3:45–4:15", "Fim de jogo → Play Online de novo", "O results recebeu o resultado e a recomendação foi atualizada."],
  ["4:15–4:45", "Terminal: `docker compose stop ai-bot`, depois Play vs AI e PvP", "Isolamento de falhas: só o modo contra IA para; o painel mostra AI Bot em vermelho."],
  ["4:45–5:00", "GitHub Actions com os testes aprovados", "Testes automatizados de todos os serviços e componentes."],
], [1.6, 4.4, 5]);

// ---------------------------------------------------------------- 11 Considerações finais
H1("11 CONSIDERAÇÕES FINAIS");
P("O projeto entregou um jogo digital não violento cuja parte online é um sistema de cinco microsserviços de negócio atrás de um API Gateway, com dados próprios por serviço, falhas isoladas e contratos versionados. A organização em componentes de software permitiu que a mesma simulação da partida rodasse no jogo offline, no servidor autoritativo e no bot, e que o mesmo codec e o mesmo formato de credencial fossem compartilhados entre linguagens. O sistema de recomendação, implementado como microsserviço independente, transforma o histórico de partidas em recomendações de nível de IA e de rivais, e a interface do jogo passou a evidenciar os microsserviços em execução e os usados por cada ação.");
P("O Scrum, adaptado a uma equipe de dois integrantes, organizou a evolução em seis sprints, do protótipo em C++ ao sistema online, sempre com um incremento jogável e testado. As principais limitações conhecidas são a ausência de contas de usuário (os jogadores são convidados identificados por UUID), uma única instância do match runtime e do ai-bot e a ausência de predição no cliente; elas constam como trabalhos futuros no Product Backlog (itens PB19 a PB21), ao lado do uso das recomendações de rivais para um matchmaking automático.");

// ================================================================ PÓS-TEXTUAIS
H1u("REFERÊNCIAS");
const refs = [
  "BERNIER, Y. W. Latency compensating methods in client/server in-game protocol design and optimization. *In*: GAME DEVELOPERS CONFERENCE, 2001, San Jose. **Proceedings** [...]. San Jose: GDC, 2001.",
  `CADDY. **Caddy documentation**. [*S. l.*], 2026. Disponível em: https://caddyserver.com/docs/. ${ACESSO}`,
  "CSIKSZENTMIHALYI, M. **Flow**: the psychology of optimal experience. New York: Harper & Row, 1990.",
  `DOCKER. **Docker Compose documentation**. [*S. l.*], 2026. Disponível em: https://docs.docker.com/compose/. ${ACESSO}`,
  "ELO, A. E. **The rating of chessplayers, past and present**. New York: Arco, 1978.",
  `FASTAPI. **FastAPI documentation**. [*S. l.*], 2026. Disponível em: https://fastapi.tiangolo.com/. ${ACESSO}`,
  `FOWLER, M.; LEWIS, J. **Microservices**: a definition of this new architectural term. [*S. l.*], 25 mar. 2014. Disponível em: https://martinfowler.com/articles/microservices.html. ${ACESSO}`,
  "GAMMA, E. *et al*. **Padrões de projeto**: soluções reutilizáveis de software orientado a objetos. Porto Alegre: Bookman, 2000.",
  `GODOT ENGINE. **Godot Engine documentation**. [*S. l.*], 2026. Disponível em: https://docs.godotengine.org/en/stable/. ${ACESSO}`,
  "HUNICKE, R. The case for dynamic difficulty adjustment in games. *In*: INTERNATIONAL CONFERENCE ON ADVANCES IN COMPUTER ENTERTAINMENT TECHNOLOGY, 2., 2005, Valencia. **Proceedings** [...]. New York: ACM, 2005. p. 429-433.",
  "NEWMAN, S. **Building microservices**: designing fine-grained systems. 2. ed. Sebastopol: O'Reilly, 2021.",
  `POSTGRESQL GLOBAL DEVELOPMENT GROUP. **PostgreSQL 17 documentation**. [*S. l.*], 2026. Disponível em: https://www.postgresql.org/docs/17/. ${ACESSO}`,
  "PRESSMAN, R. S.; MAXIM, B. R. **Engenharia de software**: uma abordagem profissional. 9. ed. Porto Alegre: AMGH, 2021.",
  "RICHARDSON, C. **Microservices patterns**: with examples in Java. Shelter Island: Manning, 2018.",
  `SCHWABER, K.; SUTHERLAND, J. **The Scrum Guide**: the definitive guide to Scrum: the rules of the game. [*S. l.*], 2020. Disponível em: https://scrumguides.org/. ${ACESSO}`,
  "SOMMERVILLE, I. **Engenharia de software**. 10. ed. São Paulo: Pearson Education do Brasil, 2018.",
  "SZYPERSKI, C. **Component software**: beyond object-oriented programming. 2. ed. London: Addison-Wesley, 2002.",
  `WORLD FOOTBALL ELO RATINGS. **About the World Football Elo Ratings**. [*S. l.*], 2026. Disponível em: https://www.eloratings.net/about. ${ACESSO}`,
];
// NBR 6023: ordem alfabética, alinhadas à esquerda, espaço simples, separadas por uma linha em branco simples.
refs.forEach((r) => children.push(new Paragraph({ children: runs(r), alignment: AlignmentType.LEFT,
  spacing: { line: LINE_1, lineRule: AUTO, after: 240 } })));

// ================================================================ páginas
// Sem o texto do PDF, os números são provisórios ("99", mesma largura). Com ele,
// cada título e legenda é procurado, em ordem, a partir da primeira página
// textual; o índice da página no PDF (capa = 0) é o número ABNT, pois a contagem
// começa na folha de rosto.
let pageOf = () => "99";
if (PAGES_TXT) {
  const norm = (s) => s.replace(/[`*]/g, "").replace(/\s+/g, " ").trim();
  const pages = fs.readFileSync(PAGES_TXT, "utf8").split("\f").map(norm);
  const start = pages.findIndex((p) => p.includes("Este relatório documenta o projeto"));
  const locate = (entries, keyOf) => {
    let from = start;
    for (const e of entries) {
      const key = norm(keyOf(e));
      let i = from;
      while (i < pages.length && !pages[i].includes(key)) i++;
      if (i >= pages.length) throw new Error(`não encontrado no PDF: ${key}`);
      e.page = i;
      from = i;
    }
  };
  locate(tocEntries, (e) => e.text.slice(0, 28));
  locate(figEntries, (e) => e.key);
  locate(quadEntries, (e) => e.key);
  locate(codEntries, (e) => e.key);
  pageOf = (e) => String(e.page);
  console.log("pages:", [tocEntries, figEntries, quadEntries, codEntries].map((l) => l.map((e) => e.page).join(",")).join(" | "));
}
buildLists(pageOf);

// ================================================================ documento
const header = new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
  children: [new TextRun({ children: [PageNumber.CURRENT], size: 20 })] })] });
const emptyHeader = new Header({ children: [new Paragraph({ children: [] })] });
const page = { size: { width: 11906, height: 16838 },
  margin: { top: 3 * CM, left: 3 * CM, bottom: 2 * CM, right: 2 * CM, header: 2 * CM } };
const doc = new Document({
  creator: "Erick Keven da Silva Alves; Antonio Guilherme da Silva",
  title: "Inazuma Eleven GL: um jogo digital não violento usando microservices e componentes de software",
  description: "Relatório de projeto – Engenharia de Software",
  styles: {
    default: { document: { run: { font: FONT, size: 24 }, paragraph: { spacing: { line: LINE_15, lineRule: AUTO, after: 0 } } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 24, bold: true, font: FONT, color: "000000", allCaps: true },
        paragraph: { spacing: { before: 0, after: LINE_15, line: LINE_15, lineRule: AUTO }, outlineLevel: 0, keepNext: true } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 24, bold: false, font: FONT, color: "000000", allCaps: true },
        paragraph: { spacing: { before: LINE_15, after: LINE_15, line: LINE_15, lineRule: AUTO }, outlineLevel: 1, keepNext: true } },
      { id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 24, bold: true, font: FONT, color: "000000" },
        paragraph: { spacing: { before: LINE_15, after: LINE_15, line: LINE_15, lineRule: AUTO }, outlineLevel: 2, keepNext: true } },
      { id: "TituloSemNumero", name: "Titulo sem numero", basedOn: "Normal", next: "Normal",
        run: { size: 24, bold: true, font: FONT, allCaps: true },
        paragraph: { alignment: AlignmentType.CENTER, spacing: { before: 0, after: LINE_15, line: LINE_15, lineRule: AUTO } } },
    ],
  },
  numbering: { config: numberingConfigs },
  sections: [
    // Capa: não é contada nem numerada.
    { properties: { page }, headers: { default: emptyHeader }, children: capa },
    // Pré-textuais: contados a partir da folha de rosto, sem número impresso.
    { properties: { page: { ...page, pageNumbers: { start: 1 } } }, headers: { default: emptyHeader }, children: pre },
    // Textuais e pós-textuais: número no canto superior direito.
    { properties: { page }, headers: { default: header }, children },
  ],
});

const out = path.join(ROOT, "docs/relatorio/Relatorio_Inazuma_Eleven_GL.docx");
Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(out, buf); console.log("wrote", out, buf.length, "bytes"); });
