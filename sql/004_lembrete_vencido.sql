-- ============================================================================
-- Financeiro DPR - 004: lembrete no dia seguinte ao vencimento
--
-- Um segundo fluxo do n8n (n8n/boleto-vencido.json) roda todo dia de manha e
-- manda, pelo WhatsApp, o boleto das parcelas que venceram ONTEM e continuam
-- sem pagamento. Para nao repetir, ele grava aqui a hora em que cobrou.
--
--   parcelas.lembrete_vencido_em  quando o n8n mandou o lembrete de vencida.
--                                 Nulo = ainda nao cobrou. O Financeiro mostra
--                                 o selo "Cobrado" ao lado do PDF.
--
-- Quem entra no lembrete (a consulta esta no fluxo, nao aqui):
--   pago = false, boleto anexado, casa com telefone, lembrete_vencido_em nulo,
--   e data_vencimento entre ontem e 7 dias atras (janela de seguranca: o
--   que venceu ha mais tempo nunca recebe cobranca em massa).
--
-- Anexar outro PDF ou tirar o boleto zera este campo junto com o "Enviado":
-- e um boleto novo, o ciclo recomeca.
--
-- COMO RODAR
-- Supabase > SQL Editor > New query > colar este arquivo inteiro > Run.
-- Pode rodar mais de uma vez ("if not exists"). Precisa do 002 ja rodado.
-- ============================================================================

alter table public.parcelas
  add column if not exists lembrete_vencido_em timestamptz;

comment on column public.parcelas.lembrete_vencido_em is
  'Quando o n8n mandou o lembrete de parcela vencida (dia seguinte ao vencimento) pelo WhatsApp. Nulo = ainda nao cobrou.';

-- Indice parcial para a consulta diaria do n8n (poucas linhas: so o que esta
-- em aberto com boleto e sem lembrete).
create index if not exists parcelas_lembrete_vencido_idx
  on public.parcelas (data_vencimento)
  where pago = false and boleto_caminho is not null and lembrete_vencido_em is null;
