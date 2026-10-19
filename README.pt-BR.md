# Speech to Text by Ciro Cesar Maciel

**Ditado para Mac: aperte uma tecla, fale, e o texto aparece onde está o cursor.**

A transcrição roda no seu Mac com o [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Sua voz nunca é enviada: o áudio vira texto na sua máquina e é descartado. Sem conta, sem cota de minutos, sem telemetria. Um app de barra de menus feito com Tauri e Rust.

[English](README.md)

![Speech to Text: a tela inicial, com os atalhos, a contagem do dia e as últimas transcrições](docs/overview.webp)

## Instalar

```bash
curl -fsSL https://blob.ciromaciel.click/tools/speech-to-text/install.sh | bash
```

O script baixa o `.dmg` mais recente, copia o Speech to Text para `/Applications` e abre.

Prefere a imagem de disco? [Baixe o Speech-to-Text-macos.dmg](https://blob.ciromaciel.click/tools/speech-to-text/latest/Speech-to-Text-macos.dmg). Abra e arraste o Speech to Text para Aplicativos. Ele é assinado com Developer ID e notarizado pela Apple, então o macOS abre sem aviso.

Na primeira vez, o macOS pede duas permissões: **Microfone** (para ouvir você) e **Acessibilidade** (para colar o texto onde está o cursor). As cópias instaladas se atualizam sozinhas.

## Como funciona

1. Deixe o cursor onde o texto deve entrar, em qualquer app.
2. Aperte **Cmd + Shift + Espaço** e fale. Um indicador discreto mostra que está ouvindo.
3. Aperte de novo (ou, no modo segurar, solte). O texto é colado no cursor, com pontuação e maiúsculas.

| Atalho | O que faz |
| --- | --- |
| Cmd + Shift + Espaço | Ditar. Liga e desliga por padrão; segurar para falar, com toque duplo para mãos livres, está a um ajuste |
| Cmd + Shift + T | Ditar e colar o texto já traduzido para o idioma escolhido (opcional, veja abaixo) |
| Cmd + Option + V | Colar de novo a última transcrição |
| Esc | Cancelar durante a gravação; nada é colado |

Todos os atalhos podem ser trocados na janela de ajustes, aberta pelo ícone na barra de menus.

## O que ele faz

| Recurso | Detalhe |
| --- | --- |
| Transcrição local | whisper.cpp com Metal, mantido carregado na memória para a primeira palavra não esperar |
| Modelos | tiny, base, small, medium e large-v3-turbo; o app baixa o que você escolher, do Hugging Face |
| Idiomas | Português, inglês, espanhol, francês, alemão, italiano, ou detecção automática |
| Detecção de voz | O Silero VAD corta o silêncio antes de o Whisper ouvir o áudio |
| Glossário | Nomes, marcas e siglas escritos do jeito que você cadastrou |
| Refinar e traduzir | Opcional. Tira hesitações ou traduz o ditado pelo [OpenRouter](https://openrouter.ai), com a sua chave e o modelo que você escolher |
| Histórico | O que você ditou, só texto, guardado no seu Mac por 7 ou 30 dias, ou só na memória |
| Área de transferência | Usada por menos de meio segundo para colar, e depois volta ao que tinha antes |

## Privacidade

O que sai do seu Mac, e só nesses casos:

- **Baixar um modelo**, do Hugging Face, quando você escolhe um.
- **Procurar atualização**, em `blob.ciromaciel.click`, um minuto depois de abrir e a cada 6 horas.
- **Refinar e traduzir**, só se você ligar: o texto transcrito (nunca o áudio) vai para o OpenRouter com a sua chave.

Mais nada. A fonte da interface vem dentro do app, e não há analytics nem conta.

## Compilar você mesmo

Você precisa das Xcode Command Line Tools, do [Rust](https://rustup.rs), do [Bun](https://bun.sh) e do CMake (`brew install cmake`).

```bash
git clone https://github.com/ciro-maciel/speech-to-text.git
cd speech-to-text
bun install
bash scripts/whisper.sh      # compila o whisper.cpp do código-fonte e baixa o detector de voz
bun run dev                  # ou: bun run build → src-tauri/target/release/bundle
```

O `scripts/whisper.sh` compila o `whisper-cli` e o `whisper-server` de uma versão fixa do whisper.cpp e os coloca onde o Tauri espera os sidecars. Os modelos de fala não ficam no repositório: o app baixa sob demanda para `~/Library/Application Support/speech-to-text/models`.

Um build local é assinado ad hoc, então o macOS pede Microfone e Acessibilidade de novo a cada build. O build oficial é assinado com Developer ID (`scripts/release/build-mac.sh`).

Para desenvolver, um arquivo `.env` na raiz do repositório pode definir `OPENROUTER_API_KEY` e `OPENROUTER_MODEL`, os valores padrão dos ajustes de Refinar e Traduzir.

Para conferir um build de ponta a ponta no seu Mac (o app roda com uma pasta pessoal descartável e nunca mexe nos seus ajustes):

```bash
scripts/smoke-test.sh "src-tauri/target/release/bundle/macos/Speech to Text.app/Contents/MacOS/speech-to-text" \
    src-tauri/target/release/bundle/macos/"Speech to Text.app"/Contents/MacOS \
    caminho/para/ggml-tiny.bin caminho/para/jfk.wav
```

## Limites

- Publicado só para macOS 11 ou mais novo, em Apple Silicon. O código é Tauri e também compila para Windows e Linux, mas esses builds não são publicados nem mantidos agora.
- A interface está em português por enquanto.
- Colar precisa da permissão de Acessibilidade; sem ela, o texto fica na área de transferência.

## Contribuir

Issues e pull requests são bem-vindos. Veja o [CONTRIBUTING.md](CONTRIBUTING.md).

## Licença

[MIT](LICENSE). O whisper.cpp, o detector de voz Silero, a Montserrat e os ícones mantêm as próprias licenças: veja o [NOTICE](NOTICE).

---

Feito por [Ciro Cesar Maciel](https://ciromaciel.click/?ref=oss-speech-to-text). Eu construo ferramentas e mostro como usar: mais [ferramentas grátis](https://ciromaciel.click/tools?ref=oss-speech-to-text) e [a página do Speech to Text](https://ciromaciel.click/tools/speech-to-text?ref=oss-speech-to-text).

**Quer a próxima?** [Siga @ciro-maciel](https://github.com/ciro-maciel) para as próximas ferramentas de código aberto, e clique em **Watch → Custom → Releases** acima para saber de cada versão nova.
