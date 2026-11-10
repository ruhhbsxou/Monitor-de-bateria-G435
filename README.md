# Monitor de bateria Logitech G435

Aplicativo simples para consultar a tensão da bateria do Logitech G435 conectado
ao computador pelo receptor USB LIGHTSPEED. O nível em porcentagem é estimado;
não é uma leitura oficial de carga.

## Requisitos

- Windows 10 ou 11
- Windows PowerShell
- Receptor USB LIGHTSPEED do G435 conectado
- Headset ligado e no modo LIGHTSPEED

O monitor reconhece receptores Logitech `046D:0ACB` e `046D:0ADF`. A leitura
não funciona usando somente Bluetooth.

## Como iniciar

1. Baixe ou extraia o projeto para uma pasta local.
2. Execute `Iniciar-G435.vbs` para abrir sem a janela de console.
   Alternativamente, execute `Iniciar-G435.bat`.
3. Clique em **Atualizar** para consultar a bateria.

Não há atualização automática. A janela pode ser minimizada para a barra de
tarefas, movida pelo topo escuro ou fechada pelo botão `x`.

## Precisão e áudio

O receptor fornece a tensão da bateria. O percentual é uma aproximação por uma
curva genérica e pode variar, especialmente durante o carregamento por USB.

No receptor `046D:0ACB`, consultar a bateria troca temporariamente o modo do
receptor e pode interromper brevemente o áudio. Por isso, a consulta é manual.

## Solução de problemas

- **Receptor não encontrado:** confira se o dongle LIGHTSPEED está conectado e
  reinicie o monitor.
- **Headset sem resposta:** confirme que ele está ligado e em modo LIGHTSPEED.
  Se necessário, desligue-o, desconecte o dongle por 10 segundos, reconecte-o e
  ligue o headset.
- A luz ciano por alguns segundos indica LIGHTSPEED; a luz azul indica Bluetooth.

## Arquivos

- `G435BatteryMonitor.ps1` — interface e leitura do receptor.
- `Iniciar-G435.vbs` e `Iniciar-G435.bat` — iniciadores do aplicativo.
- `material/` — logo PNG/SVG e ícone ICO.

O aplicativo funciona localmente e não envia dados pela internet.
