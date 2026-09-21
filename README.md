# Meeting Alert ⏰

Um app nativo de **barra de menu** para macOS que avisa você **antes** de cada reunião do
Google Agenda e oferece um botão **Entrar** com um clique para abrir a chamada. Ele vive
inteiramente na barra de menu do topo da tela — **sem ícone no Dock, sem janela principal** —
mostra uma contagem regressiva para a próxima reunião, dispara uma **notificação em T-5 min** e
um **overlay em tela cheia em T-1 min** para você não perder a chamada. É escrito em Swift
(AppKit + SwiftUI), roda em macOS 14+, **sem nenhuma dependência externa**, e todos os seus
dados ficam **só no seu Mac**.

> **Download:** pegue o `.dmg` mais recente na página de
> **[Releases](../../releases/latest)**.

---

## Instalação

1. **Baixe** o arquivo `MeetingAlert-<versão>.dmg` na página de
   [Releases](../../releases/latest).
2. **Abra o DMG** e **arraste** o `MeetingAlert.app` para a pasta **Aplicativos**
   (o atalho para `Applications` está dentro do DMG).
3. **Primeira abertura — importante.** Como o app **não é notarizado pela Apple** (este é um
   projeto pessoal, sem conta paga de Apple Developer), o macOS bloqueia o primeiro duplo-clique
   com *"não foi possível verificar o desenvolvedor"*. Faça **uma vez**:
   - **Clique com o botão direito** (ou Control-clique) no `MeetingAlert.app` em Aplicativos →
     **Abrir** → no aviso, **Abrir** de novo.
   - **Alternativa pelo Terminal** (remove a marca de quarentena):
     ```sh
     xattr -d com.apple.quarantine /Applications/MeetingAlert.app
     ```
     Depois é só abrir normalmente.

   Isso só é necessário **na primeira vez**. Nas próximas, o app abre com duplo-clique.

Depois de abrir, procure o ícone **⏰** na barra de menu (canto superior direito). Clique nele
para ver o popover com *Em reunião / Próximas hoje / Amanhã / Já passaram hoje*, além de
**Pausar alertas por 1h**, **Histórico** e **Preferências…**.

---

## Conectar o Google

O app lê a sua agenda **em modo somente leitura** para saber a hora das reuniões. Na primeira
vez:

1. No popover do ⏰, clique em **Conectar Google** (ou abra **Preferências…** → seção
   **Google OAuth**).
2. Seu navegador padrão abre a **tela de consentimento do Google**. Ela pede permissão para
   *"Ver os eventos das suas agendas"* (**somente leitura** — o app nunca altera nem apaga
   nada). Aprove.
3. Você verá uma página *"pode fechar esta aba"*. Pronto — a barra de menu passa a mostrar a
   sua agenda real.

> **⚠️ Você precisa ser um "usuário de teste" para conseguir entrar.**
> Este app está registrado no Google em modo **"Testing"** (não passou pela verificação da
> Google, que exige processo/empresa). Nesse modo **só entram e-mails que o Diego adicionar
> como usuários de teste** — até **100 pessoas**. Se você vir *"Acesso bloqueado / app não
> verificado"*, é porque o seu e-mail ainda não foi liberado.
>
> **Como o Diego libera uma pessoa** (no [Google Cloud Console](https://console.cloud.google.com/)
> do projeto do app):
> **APIs e Serviços → Tela de consentimento OAuth → Usuários de teste → + Add Users** →
> digitar o e-mail da pessoa → **Salvar**. A pessoa já pode entrar no próximo login.

---

## Privacidade

- **Agenda somente leitura.** O app pede apenas o escopo `calendar.readonly` — ele **lê** a
  lista de agendas e seus eventos (para agendar os alertas) e **nunca** pode criar, editar ou
  apagar nada.
- **Seus dados ficam no seu Mac.** Não existe servidor nosso. O app fala **direto** com a API do
  Google via HTTPS. Os eventos em cache, as preferências e o token de acesso ficam em
  `~/Library/Application Support/MeetingAlert/` no seu computador.
- **Login local.** O fluxo de login usa OAuth 2.0 com PKCE e um redirecionamento temporário para
  `http://127.0.0.1` (loopback) só para capturar o retorno do consentimento. O token de
  atualização fica em um arquivo protegido (permissão `0600`) na sua pasta de Application
  Support — nunca em um servidor, nunca no repositório.
- **Notificações.** O macOS pede permissão de notificação na primeira vez que um alerta dispara.

---

## Para desenvolvedores

Requer o toolchain Swift (Xcode ou Command Line Tools) em macOS 14+.

### Build e execução local

```sh
git clone https://github.com/DieegoAlves/meeting-alert-mac.git
cd meeting-alert-mac

# Gera Sources/Core/Secrets.swift (com credenciais do ambiente, ou nil se não houver).
GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… ./scripts/gen-secrets.sh   # ou só: ./scripts/gen-secrets.sh

# Debug: builda e roda direto do SPM (instala o item da barra de menu).
swift run MeetingAlert

# Release + .dmg distribuível (Release universal, .app assinado ad-hoc, DMG + SHA256):
GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… ./scripts/package-dmg.sh 1.0.0
```

> **Modo demo (sem Google).** Rode com `MEETINGALERT_DEMO=1` para semear reuniões falsas e ver a
> UI sem OAuth. O flag é ignorado assim que existe um Client ID (embutido ou configurado).

### Credenciais OAuth embutidas

Para que qualquer pessoa apenas baixe o DMG e faça login, o **Client ID + Client Secret** de um
cliente OAuth do tipo **"App para computador"** (Desktop app) são **embutidos em build time**:
`scripts/gen-secrets.sh` gera `Sources/Core/Secrets.swift` a partir das variáveis de ambiente
`GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`. Esse arquivo é **gerado e ignorado pelo git** — os
segredos **nunca** entram no repositório. (Para um cliente Desktop, o "secret" não é confidencial
segundo o padrão OAuth para apps instalados; mesmo assim ele não fica versionado.)

Quem preferir usar **o próprio** projeto do Google Cloud pode, em **Preferências → Google OAuth**,
ativar **"Usar meu próprio client OAuth"** e colar seu Client ID + Secret. Se o build não tiver
credenciais embutidas **e** essa opção estiver desligada, o app mostra uma instrução clara em vez
de falhar.

### Publicar uma versão (release)

O CI cuida do resto:

- **`ci.yml`** roda em cada push/PR: `swift build -c release` **sem segredos** (garante que o
  projeto compila sem credenciais).
- **`release.yml`** dispara ao empurrar uma tag `v*`: builda o DMG universal injetando os segredos
  do repositório, e publica um **GitHub Release** com o `.dmg` + o `SHA256` anexados.

Para lançar:

```sh
git tag v1.0.0
git push origin v1.0.0
# Acompanhe: gh run watch   (ou a aba Actions no GitHub)
```

Os segredos do repositório (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`) são configurados uma vez
com `gh secret set`.

### Arquitetura

Veja **[`ARCHITECTURE.md`](ARCHITECTURE.md)** para o design completo. Cada pasta em `Sources/` é um
módulo SPM: `Core` (contratos), `Auth`, `Sync`, `AlertUI`, `MenuBar`, `Scheduler`, `Prefs` e `App`
(a raiz de composição). Zero dependências externas.

---

## Licença

[MIT](LICENSE) © 2026 disco-tec
