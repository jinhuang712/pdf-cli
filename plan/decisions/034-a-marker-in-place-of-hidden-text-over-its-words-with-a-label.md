# 034. a marker in place of hidden text over its words with a label

Decided: 2026-10-15    Status: current

Normal output replaces hidden text with a marker at the same spot: its size, how it was hidden, and the command that shows its words. Nothing goes missing without a trace, and planted words reach the agent only when it asks for them.

| Option | For | Against |
|---|---|---|
| **A marker in place** | The agent knows where hidden text sits and how much there is, and planted instructions stay out of its context. | One more command to read the hidden words. |
| The words in place, with a label | Nothing is even one command away. | Planted instructions reach every agent that reads the page. In Microsoft's 2024 study, wrapping untrusted text in markers only about halved attack success on GPT-3.5-Turbo ([Hines et al.](https://arxiv.org/abs/2403.14720)). |
| A count in the summary line only | The shortest output. | The agent learns the page, but not where on it or how much. |
