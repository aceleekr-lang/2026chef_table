-- =====================================================================
--  셰프의 테이블 × 강레오  시식권 추첨 시스템  (통합 Supabase, chef_ 접두어)
--  Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run  (재실행 가능)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. 테이블
-- ---------------------------------------------------------------------
create table if not exists chef_settings (
  id                 int primary key default 1 check (id = 1),
  event_name         text not null default '2026 밀양 매운맛 페스티벌',
  program_name       text not null default '셰프의 테이블',
  chef_name          text not null default '강레오 셰프',
  tagline            text not null default '밀양의 매운맛, 셰프의 손끝에서 다시 태어나다',
  notice             text not null default '시식권은 1인 1매, 당첨 회차 시식 시간에 무대 앞 시식존에서 스탭에게 화면을 보여주세요.',
  admin_password     text not null default 'chef2026',
  staff_pin          text not null default '1111',
  test_mode          boolean not null default false,
  base_prob          numeric not null default 0.25,   -- 오픈 직후 기본 당첨 확률
  final_rush_minutes int not null default 15,         -- 마감 N분 전부터 남은 티켓 전원 당첨
  survey             jsonb not null default '[]'::jsonb,
  updated_at         timestamptz not null default now()
);

create table if not exists chef_sessions (
  id            text primary key,          -- sat1 / sun1 / sun2
  sort          int not null default 0,
  day_label     text not null,             -- 토요일 / 일요일
  round_label   text not null,             -- 1회차 / 2회차
  date_label    text not null,             -- 10.31(토)
  host_time     text not null,             -- 사회자 멘트 시작 15:00
  tasting_time  text not null,             -- 시식 15:30
  open_at       timestamptz not null,
  close_at      timestamptz not null,      -- 사회자 멘트 10분 전
  capacity      int not null default 90,
  override      text not null default 'auto' check (override in ('auto','open','closed')),
  enabled       boolean not null default true
);

create table if not exists chef_entries (
  id          bigserial primary key,
  created_at  timestamptz not null default now(),
  is_test     boolean not null default false,
  session_id  text not null references chef_sessions(id) on delete cascade,
  device_id   text not null,
  phone       text not null,
  name        text not null,
  region      text,
  gender      text,
  age_group   text,
  answers     jsonb not null default '{}'::jsonb,
  won         boolean not null default false,
  ticket_no   int,
  ticket_code text unique,
  prob        numeric,
  used_at     timestamptz,
  note        text
);

create unique index if not exists chef_entries_dev_uq   on chef_entries(session_id, device_id, is_test);
create unique index if not exists chef_entries_phone_uq on chef_entries(session_id, phone, is_test);
create index        if not exists chef_entries_won_idx  on chef_entries(session_id, is_test, won);

-- 테이블 직접 접근 차단 (모든 접근은 아래 RPC 함수로만)
alter table chef_settings enable row level security;
alter table chef_sessions enable row level security;
alter table chef_entries  enable row level security;
revoke all on chef_settings, chef_sessions, chef_entries from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. 초기 데이터
-- ---------------------------------------------------------------------
insert into chef_settings (id, survey) values (1, '[
  {"key":"companion","label":"누구와 함께 오셨나요?","type":"radio","required":true,
   "options":["혼자","가족","친구","연인","단체/모임"]},
  {"key":"visit","label":"밀양 방문은 몇 번째인가요?","type":"radio","required":true,
   "options":["밀양 거주","첫 방문","2~3회","4회 이상"]},
  {"key":"channel","label":"축제를 어떻게 알게 되셨나요?","type":"radio","required":true,
   "options":["SNS(인스타·유튜브 등)","지인 추천","현수막·포스터","뉴스·기사","우연히 방문","기타"]},
  {"key":"spicy","label":"평소 매운맛 선호도는?","type":"scale","required":true,"min":1,"max":5,
   "minLabel":"순한맛","maxLabel":"극강매운맛"},
  {"key":"interest","label":"기대되는 프로그램을 모두 골라주세요","type":"checkbox","required":false,
   "options":["셰프의 테이블","매운맛 챌린지","공연·DJ","푸드트럭","체험부스","쇼츠 공모전"]},
  {"key":"revisit","label":"내년 축제에 다시 오실 의향은?","type":"radio","required":true,
   "options":["꼭 올 것","아마도","잘 모르겠음"]}
]'::jsonb)
on conflict (id) do nothing;

insert into chef_sessions (id, sort, day_label, round_label, date_label, host_time, tasting_time, open_at, close_at, capacity) values
 ('sat1', 1, '토요일', '1회차', '10.31(토)', '15:00', '15:30', '2026-10-31 10:00:00+09', '2026-10-31 14:50:00+09', 90),
 ('sun1', 2, '일요일', '1회차', '11.01(일)', '13:00', '13:30', '2026-11-01 10:00:00+09', '2026-11-01 12:50:00+09', 90),
 ('sun2', 3, '일요일', '2회차', '11.01(일)', '15:00', '15:30', '2026-11-01 10:00:00+09', '2026-11-01 14:50:00+09', 90)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 3. 확률 계산 (시간 가중 자동 조정)
--    - 오픈 직후 base_prob 에서 시작, 마감에 가까울수록 상승
--    - 목표 페이스(capacity × 경과비율)보다 뒤처지면 가산, 너무 앞서면 감속
--    - 마감 final_rush_minutes 전부터는 남은 티켓 전원 당첨(100%)
--    - 테스트모드는 항상 50%
-- ---------------------------------------------------------------------
create or replace function chef_calc_prob(s chef_sessions, st chef_settings, won_cnt int, v_now timestamptz, v_test boolean)
returns numeric language plpgsql immutable as $$
declare remaining int; elapsed numeric; p numeric; target numeric;
begin
  remaining := s.capacity - won_cnt;
  if remaining <= 0 then return 0; end if;
  if v_test then return 0.5; end if;
  if s.close_at > s.open_at then
    elapsed := least(1, greatest(0, extract(epoch from (v_now - s.open_at)) / extract(epoch from (s.close_at - s.open_at))));
  else elapsed := 1; end if;
  p := st.base_prob + (1 - st.base_prob) * power(elapsed, 1.5);
  target := s.capacity * elapsed;
  if won_cnt < target then p := least(1, p + (target - won_cnt) / s.capacity * 2); end if;
  if won_cnt > target + s.capacity * 0.15 then p := st.base_prob * 0.5; end if;
  if v_now >= s.close_at - make_interval(mins => st.final_rush_minutes) then p := 1; end if;
  return round(least(1, greatest(0, p)), 4);
end $$;

create or replace function chef_session_status(s chef_sessions, v_now timestamptz, v_test boolean)
returns text language sql immutable as $$
  select case
    when not s.enabled then 'disabled'
    when v_test then 'open'
    when s.override = 'open' then 'open'
    when s.override = 'closed' then 'closed'
    when v_now < s.open_at then 'before'
    when v_now >= s.close_at then 'closed'
    else 'open' end
$$;

-- ---------------------------------------------------------------------
-- 4. 공개 RPC (참가자 페이지)
-- ---------------------------------------------------------------------
create or replace function chef_public_state(p_test boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare st chef_settings; v_test boolean; v_now timestamptz := now(); out_sessions json;
begin
  select * into st from chef_settings where id = 1;
  v_test := coalesce(p_test,false) or st.test_mode;
  select json_agg(json_build_object(
      'id', s.id, 'day_label', s.day_label, 'round_label', s.round_label, 'date_label', s.date_label,
      'host_time', s.host_time, 'tasting_time', s.tasting_time, 'open_at', s.open_at, 'close_at', s.close_at,
      'capacity', s.capacity, 'enabled', s.enabled,
      'won', w.cnt, 'remaining', greatest(0, s.capacity - w.cnt),
      'status', chef_session_status(s, v_now, v_test)
    ) order by s.sort)
  into out_sessions
  from chef_sessions s
  cross join lateral (select count(*)::int cnt from chef_entries e where e.session_id = s.id and e.is_test = v_test and e.won) w;

  return json_build_object(
    'now', v_now, 'test_mode', v_test,
    'event_name', st.event_name, 'program_name', st.program_name, 'chef_name', st.chef_name,
    'tagline', st.tagline, 'notice', st.notice, 'survey', st.survey,
    'sessions', coalesce(out_sessions, '[]'::json));
end $$;

create or replace function chef_my_entries(p_device text, p_test boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare st chef_settings; v_test boolean;
begin
  select * into st from chef_settings where id = 1;
  v_test := coalesce(p_test,false) or st.test_mode;
  return coalesce((select json_agg(json_build_object(
      'id', e.id, 'session_id', e.session_id, 'day_label', s.day_label, 'round_label', s.round_label,
      'date_label', s.date_label, 'tasting_time', s.tasting_time, 'host_time', s.host_time,
      'won', e.won, 'ticket_no', e.ticket_no, 'ticket_code', e.ticket_code, 'name', e.name,
      'phone', e.phone, 'used_at', e.used_at, 'created_at', e.created_at, 'is_test', e.is_test
    ) order by s.sort)
    from chef_entries e join chef_sessions s on s.id = e.session_id
    where e.device_id = p_device and e.is_test = v_test), '[]'::json);
end $$;

create or replace function chef_draw(
  p_device text, p_session text, p_name text, p_phone text,
  p_region text, p_gender text, p_age text, p_answers jsonb default '{}'::jsonb, p_test boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare
  st chef_settings; s chef_sessions; v_test boolean; v_now timestamptz := now();
  won_cnt int; p numeric; v_won boolean; v_no int; v_code text; v_phone text; e chef_entries; other chef_entries;
  st_status text;
begin
  select * into st from chef_settings where id = 1;
  v_test := coalesce(p_test,false) or st.test_mode;
  v_phone := regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g');
  if length(v_phone) < 10 or length(trim(coalesce(p_name,''))) < 1 then
    return json_build_object('result','invalid','message','이름과 휴대폰 번호를 정확히 입력해 주세요.');
  end if;

  select * into s from chef_sessions where id = p_session;
  if not found or not s.enabled then
    return json_build_object('result','invalid','message','선택한 회차를 찾을 수 없습니다.');
  end if;

  -- 같은 회차 재응모 차단 (기기 또는 전화번호)
  select * into e from chef_entries where session_id = p_session and is_test = v_test
     and (device_id = p_device or phone = v_phone) limit 1;
  if found then
    return json_build_object('result','already','won',e.won,'ticket_code',e.ticket_code,'ticket_no',e.ticket_no,
      'message','이미 이 회차에 응모하셨습니다.');
  end if;

  -- 다른 회차 당첨자는 재도전 불가
  select e2.* into other from chef_entries e2 where e2.is_test = v_test and e2.won
     and (e2.device_id = p_device or e2.phone = v_phone) limit 1;
  if found then
    return json_build_object('result','winner_other','ticket_code',other.ticket_code,'session_id',other.session_id,
      'message','이미 다른 회차 시식권에 당첨되셨습니다. 시식권은 1인 1매입니다.');
  end if;

  st_status := chef_session_status(s, v_now, v_test);
  if st_status <> 'open' then
    return json_build_object('result','closed','status',st_status,
      'message', case when st_status='before' then '아직 응모 시간이 아닙니다.' else '이 회차 응모가 마감되었습니다.' end);
  end if;

  -- 동시 응모 직렬화
  perform pg_advisory_xact_lock(hashtext('chef_draw_' || p_session || v_test::text));
  select count(*)::int into won_cnt from chef_entries where session_id = p_session and is_test = v_test and won;
  p := chef_calc_prob(s, st, won_cnt, v_now, v_test);
  v_won := random() < p;

  if v_won then
    v_no := won_cnt + 1;
    v_code := upper(p_session) || '-' || lpad(v_no::text, 3, '0') || '-' || upper(substr(encode(gen_random_bytes(3),'hex'),1,4));
  end if;

  insert into chef_entries (is_test, session_id, device_id, phone, name, region, gender, age_group, answers, won, ticket_no, ticket_code, prob)
  values (v_test, p_session, p_device, v_phone, trim(p_name), p_region, p_gender, p_age, coalesce(p_answers,'{}'::jsonb), v_won, v_no, v_code, p)
  returning * into e;

  return json_build_object(
    'result', case when v_won then 'win' else 'lose' end,
    'entry_id', e.id, 'ticket_no', v_no, 'ticket_code', v_code, 'prob', p,
    'remaining', greatest(0, s.capacity - won_cnt - case when v_won then 1 else 0 end),
    'day_label', s.day_label, 'round_label', s.round_label, 'date_label', s.date_label,
    'tasting_time', s.tasting_time, 'host_time', s.host_time, 'name', e.name, 'is_test', v_test);
end $$;

-- 스탭 PIN 으로 사용완료 처리
create or replace function chef_use_ticket(p_code text, p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare st chef_settings; e chef_entries;
begin
  select * into st from chef_settings where id = 1;
  if coalesce(p_pin,'') <> st.staff_pin then
    return json_build_object('ok',false,'message','스탭 PIN이 올바르지 않습니다.');
  end if;
  select * into e from chef_entries where ticket_code = upper(trim(p_code)) and won;
  if not found then return json_build_object('ok',false,'message','시식권을 찾을 수 없습니다.'); end if;
  if e.used_at is not null then
    return json_build_object('ok',false,'already',true,'used_at',e.used_at,'message','이미 사용 처리된 시식권입니다.');
  end if;
  update chef_entries set used_at = now() where id = e.id returning * into e;
  return json_build_object('ok',true,'used_at',e.used_at,'message','시식권 사용 처리되었습니다.');
end $$;

-- ---------------------------------------------------------------------
-- 5. 관리자 RPC (비밀번호 검증 후 동작)
-- ---------------------------------------------------------------------
create or replace function chef_admin(p_pw text, p_action text, p_payload jsonb default '{}'::jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare st chef_settings; v_now timestamptz := now(); r json; v_test boolean; v_session text; v_id bigint;
begin
  select * into st from chef_settings where id = 1;
  if coalesce(p_pw,'') <> st.admin_password then
    return json_build_object('ok',false,'error','비밀번호가 올바르지 않습니다.');
  end if;

  if p_action = 'login' then return json_build_object('ok',true); end if;

  if p_action = 'overview' then
    v_test := coalesce((p_payload->>'test')::boolean, false);
    select json_build_object('ok',true,'now',v_now,
      'settings', (select row_to_json(x) from (select st.event_name, st.program_name, st.chef_name, st.tagline, st.notice,
                     st.staff_pin, st.test_mode, st.base_prob, st.final_rush_minutes, st.survey) x),
      'sessions', (select json_agg(json_build_object(
          'id',s.id,'sort',s.sort,'day_label',s.day_label,'round_label',s.round_label,'date_label',s.date_label,
          'host_time',s.host_time,'tasting_time',s.tasting_time,'open_at',s.open_at,'close_at',s.close_at,
          'capacity',s.capacity,'override',s.override,'enabled',s.enabled,
          'status', chef_session_status(s, v_now, false),
          'entries', c.total, 'won', c.won, 'used', c.used, 'remaining', greatest(0, s.capacity - c.won),
          'prob_now', chef_calc_prob(s, st, c.won, v_now, false)
        ) order by s.sort)
        from chef_sessions s cross join lateral (
          select count(*)::int total, count(*) filter (where won)::int won, count(*) filter (where used_at is not null)::int used
          from chef_entries e where e.session_id = s.id and e.is_test = v_test) c),
      'test_counts', (select json_build_object('entries',count(*),'won',count(*) filter (where won)) from chef_entries where is_test)
    ) into r;
    return r;
  end if;

  if p_action = 'save_settings' then
    update chef_settings set
      event_name = coalesce(p_payload->>'event_name', event_name),
      program_name = coalesce(p_payload->>'program_name', program_name),
      chef_name = coalesce(p_payload->>'chef_name', chef_name),
      tagline = coalesce(p_payload->>'tagline', tagline),
      notice = coalesce(p_payload->>'notice', notice),
      staff_pin = coalesce(nullif(p_payload->>'staff_pin',''), staff_pin),
      admin_password = coalesce(nullif(p_payload->>'admin_password',''), admin_password),
      test_mode = coalesce((p_payload->>'test_mode')::boolean, test_mode),
      base_prob = coalesce((p_payload->>'base_prob')::numeric, base_prob),
      final_rush_minutes = coalesce((p_payload->>'final_rush_minutes')::int, final_rush_minutes),
      survey = coalesce(p_payload->'survey', survey),
      updated_at = now()
    where id = 1;
    return json_build_object('ok',true);
  end if;

  if p_action = 'save_session' then
    update chef_sessions set
      day_label = coalesce(p_payload->>'day_label', day_label),
      round_label = coalesce(p_payload->>'round_label', round_label),
      date_label = coalesce(p_payload->>'date_label', date_label),
      host_time = coalesce(p_payload->>'host_time', host_time),
      tasting_time = coalesce(p_payload->>'tasting_time', tasting_time),
      open_at = coalesce((p_payload->>'open_at')::timestamptz, open_at),
      close_at = coalesce((p_payload->>'close_at')::timestamptz, close_at),
      capacity = coalesce((p_payload->>'capacity')::int, capacity),
      override = coalesce(p_payload->>'override', override),
      enabled = coalesce((p_payload->>'enabled')::boolean, enabled)
    where id = p_payload->>'id';
    return json_build_object('ok',true);
  end if;

  if p_action = 'entries' then
    v_test := coalesce((p_payload->>'test')::boolean, false);
    v_session := nullif(p_payload->>'session_id','');
    return json_build_object('ok',true,'rows', coalesce((select json_agg(json_build_object(
        'id',e.id,'created_at',e.created_at,'session_id',e.session_id,'day_label',s.day_label,'round_label',s.round_label,
        'name',e.name,'phone',e.phone,'region',e.region,'gender',e.gender,'age_group',e.age_group,'answers',e.answers,
        'won',e.won,'ticket_no',e.ticket_no,'ticket_code',e.ticket_code,'prob',e.prob,'used_at',e.used_at,'note',e.note,'device_id',e.device_id
      ) order by e.won desc, e.ticket_no, e.created_at)
      from chef_entries e join chef_sessions s on s.id = e.session_id
      where e.is_test = v_test
        and (v_session is null or e.session_id = v_session)
        and (not coalesce((p_payload->>'won_only')::boolean,false) or e.won)), '[]'::json));
  end if;

  if p_action = 'set_used' then
    v_id := (p_payload->>'id')::bigint;
    update chef_entries set used_at = case when coalesce((p_payload->>'used')::boolean,true) then now() else null end where id = v_id;
    return json_build_object('ok',true);
  end if;

  if p_action = 'set_note' then
    update chef_entries set note = p_payload->>'note' where id = (p_payload->>'id')::bigint;
    return json_build_object('ok',true);
  end if;

  if p_action = 'delete_entry' then
    delete from chef_entries where id = (p_payload->>'id')::bigint;
    return json_build_object('ok',true);
  end if;

  -- 수동 당첨 처리 (낙첨자를 당첨으로 전환, 현장 보정용)
  if p_action = 'force_win' then
    v_id := (p_payload->>'id')::bigint;
    update chef_entries e set won = true,
      ticket_no = (select coalesce(max(ticket_no),0)+1 from chef_entries x where x.session_id = e.session_id and x.is_test = e.is_test),
      ticket_code = upper(e.session_id) || '-M' || lpad(((select coalesce(max(ticket_no),0)+1 from chef_entries x where x.session_id = e.session_id and x.is_test = e.is_test))::text,3,'0') || '-' || upper(substr(encode(gen_random_bytes(3),'hex'),1,4))
    where id = v_id and not won;
    return json_build_object('ok',true);
  end if;

  if p_action = 'delete_test' then
    delete from chef_entries where is_test;
    return json_build_object('ok',true);
  end if;

  if p_action = 'reset_session' then
    delete from chef_entries where session_id = p_payload->>'session_id' and not is_test;
    return json_build_object('ok',true);
  end if;

  return json_build_object('ok',false,'error','알 수 없는 동작: '||p_action);
end $$;

-- ---------------------------------------------------------------------
-- 6. 권한 (anon 키로 함수만 호출 가능)
-- ---------------------------------------------------------------------
revoke all on function chef_calc_prob(chef_sessions, chef_settings, int, timestamptz, boolean) from public, anon, authenticated;
revoke all on function chef_session_status(chef_sessions, timestamptz, boolean) from public, anon, authenticated;
grant execute on function chef_public_state(boolean) to anon, authenticated;
grant execute on function chef_my_entries(text, boolean) to anon, authenticated;
grant execute on function chef_draw(text, text, text, text, text, text, text, jsonb, boolean) to anon, authenticated;
grant execute on function chef_use_ticket(text, text) to anon, authenticated;
grant execute on function chef_admin(text, text, jsonb) to anon, authenticated;

-- 완료. 관리자 초기 비밀번호: chef2026 / 스탭 PIN: 1111 (관리자 페이지에서 변경 가능)
