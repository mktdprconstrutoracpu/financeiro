-- ============================================================================
-- Financeiro DPR - 001: o backoffice que substitui a planilha
--
-- A planilha de controle (uma aba por casa) era preenchida a mao e sincronizada
-- para as tabelas unidades e parcelas, que a Central do Cliente le. Este
-- backoffice grava NAS MESMAS tabelas, direto do navegador, com login: o
-- cliente ve na Central o que a equipe gravou aqui, sem sincronizacao.
-- Mais um campo que a planilha nao tinha: o boleto do mes, por parcela.
--
-- Roda no MESMO projeto Supabase do Central DPR, do CRM e do painel de obras.
-- Tudo que este arquivo cria comeca com fin_; nas tabelas da Central ele so
-- ACRESCENTA (duas colunas e as travas de escrita da equipe).
--
-- COMO RODAR
-- Supabase > SQL Editor > New query > colar este arquivo inteiro > Run.
-- Pode rodar mais de uma vez ("if not exists", "create or replace",
-- "drop policy if exists"). Precisa do sql/001_extrato_cliente.sql da
-- Central ja rodado (as tabelas unidades, parcelas e vinculos existem).
--
-- QUEM ENTRA (Supabase > Table Editor > fin_liberacoes)
--   Todo login aparece la sozinho. Escreva liberado na coluna liberado da
--   pessoa e ela entra no financeiro; apague a palavra (ou escreva nao) e
--   ela perde o acesso. Quem e gestor do painel de obras entra sem precisar
--   disso. O cliente da Central nunca entra: sem a palavra, o banco recusa.
--
-- O QUE A EQUIPE PODE (as travas valem no banco, nao so na tela)
--   ler, criar, alterar e apagar casas (unidades) e parcelas (parcelas);
--   subir, abrir e tirar boletos (bucket boletos, privado).
--   O cliente continua lendo so a casa dele (vinculo aprovado) e abre so os
--   boletos da casa dele.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. fin_liberacoes - quem entra, escrevendo "liberado"
-- ----------------------------------------------------------------------------
create table if not exists public.fin_liberacoes (
  email          text primary key,
  nome           text,
  liberado       text,
  resultado      text,
  atualizado_em  timestamptz not null default now()
);

comment on table  public.fin_liberacoes          is 'Controle de acesso do Financeiro: escreva liberado na coluna liberado.';
comment on column public.fin_liberacoes.liberado  is 'Escreva liberado para liberar; apague ou escreva nao para tirar o acesso.';
comment on column public.fin_liberacoes.nome      is 'Como a pessoa aparece no financeiro (em branco = parte do e-mail antes do @).';
comment on column public.fin_liberacoes.resultado is 'So leitura: o banco escreve aqui o que fez.';

alter table public.fin_liberacoes enable row level security;
revoke all on table public.fin_liberacoes from public, anon, authenticated;

create or replace function public.fin_liberado_sim(p text)
returns boolean
language sql
immutable
as $$
  select lower(trim(coalesce(p, ''))) in ('liberado', 'liberada', 'liberar', 'sim', 'ok')
$$;

-- normaliza o que foi escrito e explica o que aconteceu
create or replace function public.fin_liberacoes_aplica()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid;
  v_quando text := to_char(now() - interval '3 hours', 'DD/MM/YYYY HH24:MI');  -- horario de Brasilia
begin
  if pg_trigger_depth() > 1 then
    return new;
  end if;
  new.email := lower(trim(coalesce(new.email, '')));
  if new.email = '' then
    raise exception 'Escreva o e-mail da pessoa.';
  end if;
  new.nome := nullif(trim(coalesce(new.nome, '')), '');
  new.atualizado_em := now();

  select u.id into v_uid from auth.users u where lower(u.email) = new.email limit 1;

  if public.fin_liberado_sim(new.liberado) then
    new.liberado := 'liberado';
    if v_uid is null then
      new.resultado := 'Nao achei login com este e-mail. A pessoa cria a conta primeiro (no Financeiro, na Central ou no painel de obras); depois escreva liberado de novo. ' || v_quando;
    else
      new.resultado := 'Liberado em ' || v_quando || '.';
    end if;
    return new;
  end if;

  if nullif(trim(coalesce(new.liberado, '')), '') is not null then
    new.liberado := 'nao';
  end if;
  new.resultado := case when v_uid is null
    then 'Nao achei login com este e-mail. A pessoa cria a conta primeiro. ' || v_quando
    else 'Sem acesso. Escreva liberado para liberar. ' || v_quando end;
  return new;
end;
$$;

drop trigger if exists fin_liberacoes_aplica on public.fin_liberacoes;
create trigger fin_liberacoes_aplica
  before insert or update on public.fin_liberacoes
  for each row execute function public.fin_liberacoes_aplica();

-- todo login novo aparece na tabela (e some quando o login e apagado); nunca
-- pode atrapalhar a criacao da conta: qualquer erro e engolido
create or replace function public.fin_liberacoes_novo_login()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email is null then
    return new;
  end if;
  insert into public.fin_liberacoes (email, nome, liberado, resultado)
  values (lower(trim(new.email)),
          coalesce(new.raw_user_meta_data ->> 'nome', new.raw_user_meta_data ->> 'name'),
          null,
          'Sem acesso. Escreva liberado para liberar.')
  on conflict (email) do nothing;
  return new;
exception when others then
  return new;
end;
$$;

drop trigger if exists fin_liberacoes_novo_login on auth.users;
create trigger fin_liberacoes_novo_login
  after insert on auth.users
  for each row execute function public.fin_liberacoes_novo_login();

create or replace function public.fin_liberacoes_login_apagado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.email is not null then
    delete from public.fin_liberacoes where email = lower(trim(old.email));
  end if;
  return old;
exception when others then
  return old;
end;
$$;

drop trigger if exists fin_liberacoes_login_apagado on auth.users;
create trigger fin_liberacoes_login_apagado
  after delete on auth.users
  for each row execute function public.fin_liberacoes_login_apagado();

-- preenche com quem ja existe, sem mexer em acesso nenhum
insert into public.fin_liberacoes (email, nome, liberado, resultado)
select lower(trim(u.email)),
       coalesce(u.raw_user_meta_data ->> 'nome', u.raw_user_meta_data ->> 'name'),
       null,
       'Sem acesso. Escreva liberado para liberar.'
  from auth.users u
 where u.email is not null
on conflict (email) do nothing;


-- ----------------------------------------------------------------------------
-- 2. Quem esta chamando: as funcoes que as travas usam
--
-- security definer para ler fin_liberacoes e obras_perfis por dentro, sem cair
-- nas travas delas. O gestor do painel de obras entra sem precisar da palavra.
-- ----------------------------------------------------------------------------
create or replace function public.fin_tem_acesso()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and (
    exists (select 1
              from public.fin_liberacoes l
              join auth.users u on lower(u.email) = l.email
             where u.id = auth.uid()
               and public.fin_liberado_sim(l.liberado))
    or exists (select 1
                 from public.obras_perfis p
                where p.user_id = auth.uid()
                  and p.ativo
                  and p.papel = 'gestor')
  )
$$;

-- o que a pagina pergunta ao abrir: tem acesso? como se chama?
create or replace function public.fin_perfil()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'acesso', public.fin_tem_acesso(),
    'email',  (select lower(u.email) from auth.users u where u.id = auth.uid()),
    'nome',   coalesce(
                (select l.nome from public.fin_liberacoes l join auth.users u on lower(u.email) = l.email where u.id = auth.uid()),
                (select p.nome from public.obras_perfis p where p.user_id = auth.uid()),
                (select coalesce(u.raw_user_meta_data ->> 'nome', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))
                   from auth.users u where u.id = auth.uid())),
    'gestor_obras', exists (select 1 from public.obras_perfis p where p.user_id = auth.uid() and p.ativo and p.papel = 'gestor')
  )
$$;

revoke all on function public.fin_liberado_sim(text) from public, anon;
revoke all on function public.fin_tem_acesso()       from public, anon;
revoke all on function public.fin_perfil()           from public, anon;
grant execute on function public.fin_liberado_sim(text) to authenticated;
grant execute on function public.fin_tem_acesso()       to authenticated;
grant execute on function public.fin_perfil()           to authenticated;


-- ----------------------------------------------------------------------------
-- 3. O que a planilha nao tinha: o boleto do mes, por parcela
--
-- O arquivo (PDF) fica no Storage, no bucket privado "boletos", em
-- <id da unidade>/<ordem>-<nome>.pdf; aqui fica o caminho. E a primeira pasta
-- (o id da unidade) que diz ao Storage de que casa e o boleto.
-- ----------------------------------------------------------------------------
alter table public.parcelas
  add column if not exists boleto_caminho text;

comment on column public.parcelas.boleto_caminho is
  'Caminho do boleto desta parcela no bucket boletos (privado). Nulo = sem boleto.';

-- a casa passou a ser gerida aqui: a sincronizacao da planilha (Central,
-- api/sincronizar) deixa de mexer nela, para nao desfazer o que a equipe gravou
alter table public.unidades
  add column if not exists gerida_no_financeiro boolean not null default false;

comment on column public.unidades.gerida_no_financeiro is
  'true = esta casa e preenchida no Financeiro; a sincronizacao da planilha nao a sobrescreve.';


-- ----------------------------------------------------------------------------
-- 4. As travas: a equipe do financeiro le e escreve casas e parcelas
--
-- As travas do cliente (sql/001_extrato_cliente.sql da Central) continuam:
-- ele le so a casa dele. Estas somam: quem tem acesso aqui le e escreve tudo.
-- ----------------------------------------------------------------------------
drop policy if exists unidades_financeiro on public.unidades;
create policy unidades_financeiro on public.unidades
  for all to authenticated
  using (public.fin_tem_acesso())
  with check (public.fin_tem_acesso());

drop policy if exists parcelas_financeiro on public.parcelas;
create policy parcelas_financeiro on public.parcelas
  for all to authenticated
  using (public.fin_tem_acesso())
  with check (public.fin_tem_acesso());


-- ----------------------------------------------------------------------------
-- 5. STORAGE - o bucket "boletos", PRIVADO
--
-- Ninguem abre um boleto pelo endereco: a pagina pede um link assinado, que
-- vale alguns minutos. A equipe do financeiro sobe, abre e tira; o cliente
-- da Central abre so os da casa dele (a primeira pasta do caminho e o id da
-- unidade, e o vinculo aprovado diz que a casa e dele).
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('boletos', 'boletos', false)
on conflict (id) do nothing;

drop policy if exists boletos_financeiro on storage.objects;
create policy boletos_financeiro on storage.objects
  for all to authenticated
  using (bucket_id = 'boletos' and public.fin_tem_acesso())
  with check (bucket_id = 'boletos' and public.fin_tem_acesso());

drop policy if exists boletos_cliente_le on storage.objects;
create policy boletos_cliente_le on storage.objects
  for select to authenticated
  using (bucket_id = 'boletos'
         and exists (select 1
                       from public.vinculos v
                      where v.user_id  = auth.uid()
                        and v.situacao = 'aprovado'
                        and v.unidade_id::text = (storage.foldername(name))[1]));
