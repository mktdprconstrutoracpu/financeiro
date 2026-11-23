-- ============================================================================
-- 005_permuta.sql  (23/11/2026)
--
-- Situacao nova "permuta" para unidades.status_contrato: casa dada em permuta nao
-- e venda e nao conta nos "Contratos ativos" do Financeiro. A planilha marca isso
-- no nome da aba ("CASA 52 (Permutante)", "CASA 09 (Permuta)").
-- Tambem marca as 5 permutas do Villagio Caucaia II que estavam como ativas
-- (CASAS 09, 52, 53, 67 e 72), menos as que a equipe ja salvou no Financeiro.
-- Rode no SQL Editor do Supabase. Pode rodar de novo.
-- ============================================================================

-- a regra das situacoes aceitas (o nome do check vem do create table do sql/001 da Central)
alter table public.unidades drop constraint if exists unidades_status_contrato_check;
alter table public.unidades add constraint unidades_status_contrato_check
  check (status_contrato in ('ativo', 'aguardando_assinatura', 'distrato_aguardando', 'distrato_realizado', 'permuta'));

update public.unidades
   set status_contrato = 'permuta'
 where empreendimento ilike '%caucaia%'
   and upper(split_part(trim(unidade), ' ', 1)) = 'CASA'
   and nullif(substring(unidade from '\d+'), '')::int in (9, 52, 53, 67, 72)
   and not gerida_no_financeiro
   and status_contrato is distinct from 'permuta';
