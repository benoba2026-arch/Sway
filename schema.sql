create table if not exists public.profiles (
    user_id uuid primary key references auth.users (id) on delete cascade,
    display_name text not null default '',
    username text,
    created_at timestamptz not null default now(),
    email text,
    age smallint,
    height smallint,
    level text,
    energy text,
    relationship text,
    side text,
    photo_url text,
    last_seen_at timestamptz
);

alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists age smallint;
alter table public.profiles add column if not exists height smallint;
alter table public.profiles add column if not exists level text;
alter table public.profiles add column if not exists energy text;
alter table public.profiles add column if not exists relationship text;
alter table public.profiles add column if not exists side text;
alter table public.profiles add column if not exists photo_url text;
alter table public.profiles add column if not exists last_seen_at timestamptz;

create unique index if not exists profiles_username_unique
    on public.profiles (lower(username))
    where username is not null and btrim(username) <> '';

create table if not exists public.user_roles (
    user_id uuid not null references auth.users (id) on delete cascade,
    role text not null check (role = 'admin'),
    created_at timestamptz not null default now(),
    primary key (user_id, role)
);

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;

revoke all on public.profiles from anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
revoke all on public.user_roles from anon, authenticated;
grant select on public.user_roles to authenticated;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.user_roles
        where user_id = (select auth.uid())
          and role = 'admin'
    );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

create or replace function public.touch_presence()
returns void
language sql
security definer
set search_path = ''
as $$
    update public.profiles
    set last_seen_at = now()
    where user_id = (select auth.uid());
$$;

revoke all on function public.touch_presence() from public;
grant execute on function public.touch_presence() to authenticated;


create table if not exists public.user_blocks (
    blocker_id uuid not null references auth.users (id) on delete cascade,
    blocked_id uuid not null references auth.users (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (blocker_id, blocked_id),
    check (blocker_id <> blocked_id)
);

create or replace function public.browse_profiles(
    requested_level text,
    older_than timestamptz default null,
    before_user uuid default null,
    result_limit integer default 48,
    search_text text default null
)
returns table (
    user_id uuid,
    display_name text,
    age smallint,
    level text,
    photo_url text,
    created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select p.user_id, p.display_name, p.age, p.level, p.photo_url, p.created_at
    from public.profiles p
    where (select auth.uid()) is not null
      and requested_level in ('all', '100', '200', '300', '400', '500', '600')
      and (requested_level = 'all' or p.level = requested_level)
      and p.user_id <> (select auth.uid())
      and (older_than is null or (p.created_at, p.user_id) < (older_than, before_user))
      and (
          nullif(btrim(search_text), '') is null
          or p.display_name ilike '%' || btrim(search_text) || '%'
          or coalesce(p.username, '') ilike '%' || btrim(search_text) || '%'
          or p.level ilike '%' || btrim(search_text) || '%'
      )
      and not exists (
          select 1 from public.user_blocks b
          where (b.blocker_id = (select auth.uid()) and b.blocked_id = p.user_id)
             or (b.blocker_id = p.user_id and b.blocked_id = (select auth.uid()))
      )
    order by p.created_at desc, p.user_id desc
    limit greatest(1, least(coalesce(result_limit, 48), 48));
$$;

revoke all on function public.browse_profiles(text, timestamptz, uuid, integer, text) from public, anon;
grant execute on function public.browse_profiles(text, timestamptz, uuid, integer, text) to authenticated;

create table if not exists public.conversations (
    id uuid primary key default gen_random_uuid(),
    title text,
    direct_key text unique,
    chat_type text not null default 'private' check (chat_type in ('private', 'group')),
    created_by uuid not null references auth.users (id) on delete cascade,
    created_at timestamptz not null default now()
);

alter table public.conversations add column if not exists chat_type text not null default 'private';
alter table public.conversations drop constraint if exists conversations_chat_type_check;
alter table public.conversations add constraint conversations_chat_type_check check (chat_type in ('private', 'group'));

create table if not exists public.conversation_members (
    conversation_id uuid not null references public.conversations (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    added_by uuid not null references auth.users (id) on delete cascade,
    joined_at timestamptz not null default now(),
    primary key (conversation_id, user_id)
);

update public.conversations c
set chat_type = case
    when c.direct_key is null or member_totals.total_members > 2 then 'group'
    else 'private'
end
from (
    select conversation_id, count(*) as total_members
    from public.conversation_members
    group by conversation_id
) member_totals
where c.id = member_totals.conversation_id
  and c.chat_type = 'private';

create table if not exists public.messages (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references public.conversations (id) on delete cascade,
    sender_id uuid not null references auth.users (id) on delete cascade,
    message_type text not null default 'text' check (message_type in ('text', 'sticker', 'image', 'video')),
    body text,
    media_path text,
    created_at timestamptz not null default now(),
    check (
        (message_type in ('text', 'sticker') and nullif(btrim(body), '') is not null and media_path is null)
        or (message_type in ('image', 'video') and media_path is not null and body is null)
    )
);

create index if not exists conversation_members_user_idx on public.conversation_members (user_id, conversation_id);
create index if not exists messages_conversation_created_idx on public.messages (conversation_id, created_at);
create index if not exists profiles_directory_idx on public.profiles (level, created_at desc, user_id desc);

alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.user_blocks enable row level security;
alter table public.messages enable row level security;

revoke all on public.conversations, public.conversation_members, public.user_blocks, public.messages from anon, authenticated;
grant select on public.conversations, public.conversation_members, public.user_blocks, public.messages to authenticated;
grant insert on public.messages to authenticated;

create or replace function public.can_access_chat(chat_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.conversation_members mine
        where mine.conversation_id = chat_id
          and mine.user_id = (select auth.uid())
          and not exists (
              select 1
              from public.conversation_members other_member
              join public.user_blocks b
                on (b.blocker_id = mine.user_id and b.blocked_id = other_member.user_id)
                or (b.blocker_id = other_member.user_id and b.blocked_id = mine.user_id)
              where other_member.conversation_id = chat_id
                and other_member.user_id <> mine.user_id
          )
    );
$$;

revoke all on function public.can_access_chat(uuid) from public, anon;
grant execute on function public.can_access_chat(uuid) to authenticated;

create or replace function public.can_access_chat_path(chat_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.conversations c
        where c.id::text = (storage.foldername(chat_path))[1]
          and public.can_access_chat(c.id)
    );
$$;

revoke all on function public.can_access_chat_path(text) from public, anon;
grant execute on function public.can_access_chat_path(text) to authenticated;

drop policy if exists "Members can read accessible conversations" on public.conversations;
create policy "Members can read accessible conversations"
    on public.conversations for select to authenticated
    using ((select public.can_access_chat(id)));

drop policy if exists "Members can read accessible conversation members" on public.conversation_members;
create policy "Members can read accessible conversation members"
    on public.conversation_members for select to authenticated
    using ((select public.can_access_chat(conversation_id)));

drop policy if exists "Users can read their own blocks" on public.user_blocks;
create policy "Users can read their own blocks"
    on public.user_blocks for select to authenticated
    using (blocker_id = (select auth.uid()) or blocked_id = (select auth.uid()));

drop policy if exists "Users can block other accounts" on public.user_blocks;
create policy "Users can block other accounts"
    on public.user_blocks for insert to authenticated
    with check (blocker_id = (select auth.uid()) and blocked_id <> (select auth.uid()));

drop policy if exists "Users can unblock accounts they blocked" on public.user_blocks;
create policy "Users can unblock accounts they blocked"
    on public.user_blocks for delete to authenticated
    using (blocker_id = (select auth.uid()));

drop policy if exists "Members can read messages in accessible conversations" on public.messages;
create policy "Members can read messages in accessible conversations"
    on public.messages for select to authenticated
    using ((select public.can_access_chat(conversation_id)));

drop policy if exists "Members can send messages in accessible conversations" on public.messages;
create policy "Members can send messages in accessible conversations"
    on public.messages for insert to authenticated
    with check (
        sender_id = (select auth.uid())
        and (select public.can_access_chat(conversation_id))
        and (
            message_type not in ('image', 'video')
            or (
                media_path like conversation_id::text || '/' || sender_id::text || '/%'
                and (
                    (message_type = 'image' and lower(media_path) ~ '\.(jpg|jpeg|png|webp|gif)$')
                    or (message_type = 'video' and lower(media_path) ~ '\.(mp4|webm)$')
                )
            )
        )
    );

create or replace function public.find_profiles_by_level(requested_level text)
returns table (
    user_id uuid,
    display_name text,
    age smallint,
    level text,
    photo_url text
)
language sql
stable
security definer
set search_path = ''
as $$
    select p.user_id, p.display_name, p.age, p.level, p.photo_url
    from public.profiles p
    where (select auth.uid()) is not null
      and (requested_level = 'all' or p.level = requested_level)
      and p.level in ('100', '200', '300', '400', '500', '600')
      and p.user_id <> (select auth.uid())
      and not exists (
          select 1 from public.user_blocks b
          where (b.blocker_id = (select auth.uid()) and b.blocked_id = p.user_id)
             or (b.blocker_id = p.user_id and b.blocked_id = (select auth.uid()))
      )
    order by p.created_at desc;
$$;

create or replace function public.start_direct_chat(target_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_user_id uuid := (select auth.uid());
    chat_key text;
    chat_id uuid;
begin
    if current_user_id is null or target_user is null or target_user = current_user_id then
        raise exception 'Choose another signed-in user to start a chat';
    end if;
    if not exists (select 1 from public.profiles p where p.user_id = target_user) then
        raise exception 'That user does not have a profile yet';
    end if;
    if exists (
        select 1 from public.user_blocks b
        where (b.blocker_id = current_user_id and b.blocked_id = target_user)
           or (b.blocker_id = target_user and b.blocked_id = current_user_id)
    ) then
        raise exception 'This user is blocked and cannot be added to chat';
    end if;

    chat_key := least(current_user_id::text, target_user::text) || ':' || greatest(current_user_id::text, target_user::text);
    select c.id into chat_id from public.conversations c where c.direct_key = chat_key;
    if chat_id is null then
        insert into public.conversations (direct_key, created_by, chat_type)
        values (chat_key, current_user_id, 'private')
        on conflict (direct_key) do nothing
        returning id into chat_id;
        if chat_id is null then
            select c.id into chat_id from public.conversations c where c.direct_key = chat_key;
        end if;
    end if;

    insert into public.conversation_members (conversation_id, user_id, added_by)
    values (chat_id, current_user_id, current_user_id), (chat_id, target_user, current_user_id)
    on conflict (conversation_id, user_id) do nothing;
    return chat_id;
end;
$$;

revoke all on function public.start_direct_chat(uuid) from public, anon;
grant execute on function public.start_direct_chat(uuid) to authenticated;

drop function if exists public.add_user_to_conversation(uuid, uuid);

create or replace function public.add_user_to_conversation(chat_id uuid, target_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_user_id uuid := (select auth.uid());
    target_chat_id uuid := chat_id;
    chat_record public.conversations%rowtype;
begin
    if current_user_id is null or not public.can_access_chat(chat_id) then
        raise exception 'You do not have access to this chat';
    end if;
    if target_user is null or target_user = current_user_id then
        raise exception 'Choose another user to add';
    end if;
    if not exists (select 1 from public.profiles p where p.user_id = target_user) then
        raise exception 'That user does not have a profile yet';
    end if;
    if exists (
        select 1
        from public.conversation_members existing
        join public.user_blocks b
          on (b.blocker_id = target_user and b.blocked_id = existing.user_id)
          or (b.blocker_id = existing.user_id and b.blocked_id = target_user)
        where existing.conversation_id = chat_id
    ) then
        raise exception 'This user cannot be added because a chat member has blocked them';
    end if;

    select c.* into chat_record from public.conversations c where c.id = chat_id;
    if not exists (
        select 1 from public.conversation_members
        where conversation_id = chat_id and user_id = target_user
    ) and chat_record.chat_type = 'private' then
        insert into public.conversations (created_by, chat_type)
        values (current_user_id, 'group')
        returning id into target_chat_id;
        insert into public.conversation_members (conversation_id, user_id, added_by)
        select target_chat_id, existing.user_id, current_user_id
        from public.conversation_members existing
        where existing.conversation_id = chat_id;
    end if;

    insert into public.conversation_members (conversation_id, user_id, added_by)
    values (target_chat_id, target_user, current_user_id)
    on conflict (conversation_id, user_id) do nothing;
    return target_chat_id;
end;
$$;

revoke all on function public.add_user_to_conversation(uuid, uuid) from public, anon;
grant execute on function public.add_user_to_conversation(uuid, uuid) to authenticated;

drop function if exists public.list_my_conversations();

create function public.list_my_conversations()
returns table (
    conversation_id uuid,
    chat_type text,
    title text,
    participant_names text,
    photo_url text,
    member_count bigint,
    latest_message text,
    latest_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select c.id, c.chat_type, c.title,
           string_agg(p.display_name, ', ' order by p.display_name) filter (where cm.user_id <> (select auth.uid())),
           (array_agg(p.photo_url order by p.display_name) filter (where cm.user_id <> (select auth.uid())))[1],
           count(cm.user_id),
           (select coalesce(m.body, case when m.message_type = 'sticker' then 'Sent a sticker' when m.message_type = 'image' then 'Photo' when m.message_type = 'video' then 'Video' end)
            from public.messages m
            where m.conversation_id = c.id
            order by m.created_at desc
            limit 1),
           (select m.created_at from public.messages m where m.conversation_id = c.id order by m.created_at desc limit 1)
    from public.conversations c
    join public.conversation_members cm on cm.conversation_id = c.id
    join public.profiles p on p.user_id = cm.user_id
    where public.can_access_chat(c.id)
    group by c.id
    order by coalesce((select max(m.created_at) from public.messages m where m.conversation_id = c.id), c.created_at) desc;
$$;

revoke all on function public.list_my_conversations() from public, anon;
grant execute on function public.list_my_conversations() to authenticated;

create or replace function public.get_conversation_members(chat_id uuid)
returns table (user_id uuid, display_name text, level text, photo_url text)
language sql
stable
security definer
set search_path = ''
as $$
    select p.user_id, p.display_name, p.level, p.photo_url
    from public.conversation_members cm
    join public.profiles p on p.user_id = cm.user_id
    where cm.conversation_id = chat_id
      and public.can_access_chat(chat_id)
    order by cm.joined_at;
$$;

revoke all on function public.get_conversation_members(uuid) from public, anon;
grant execute on function public.get_conversation_members(uuid) to authenticated;

create or replace function public.get_conversation_messages(chat_id uuid)
returns table (
    id uuid,
    sender_id uuid,
    sender_name text,
    sender_photo_url text,
    message_type text,
    body text,
    media_path text,
    created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select m.id, m.sender_id, p.display_name, p.photo_url, m.message_type, m.body, m.media_path, m.created_at
    from public.messages m
    join public.profiles p on p.user_id = m.sender_id
    where m.conversation_id = chat_id
      and public.can_access_chat(chat_id)
    order by m.created_at;
$$;

revoke all on function public.get_conversation_messages(uuid) from public, anon;
grant execute on function public.get_conversation_messages(uuid) to authenticated;

create or replace function public.block_user(target_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if (select auth.uid()) is null or target_user is null or target_user = (select auth.uid()) then
        raise exception 'Choose another user to block';
    end if;
    insert into public.user_blocks (blocker_id, blocked_id)
    values ((select auth.uid()), target_user)
    on conflict (blocker_id, blocked_id) do nothing;
end;
$$;

revoke all on function public.block_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-photos', 'profile-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-media', 'chat-media', false, 26214400, array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'video/mp4', 'video/webm'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Chat participants can read chat media" on storage.objects;
create policy "Chat participants can read chat media"
    on storage.objects for select to authenticated
    using (bucket_id = 'chat-media' and (select public.can_access_chat_path(name)));

drop policy if exists "Chat participants can upload chat media" on storage.objects;
create policy "Chat participants can upload chat media"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'chat-media'
        and (storage.foldername(name))[2] = (select auth.uid())::text
        and (select public.can_access_chat_path(name))
    );

do $$
begin
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
        alter publication supabase_realtime add table public.messages;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'conversation_members') then
        alter publication supabase_realtime add table public.conversation_members;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'user_blocks') then
        alter publication supabase_realtime add table public.user_blocks;
    end if;
end;
$$;

drop policy if exists "Users can read their own profile photo objects" on storage.objects;
create policy "Users can read their own profile photo objects"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );

drop policy if exists "Users can upload their own profile photo" on storage.objects;
create policy "Users can upload their own profile photo"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );

drop policy if exists "Users can update their own profile photo" on storage.objects;
create policy "Users can update their own profile photo"
    on storage.objects for update to authenticated
    using (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    )
    with check (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );

drop policy if exists "Users and admins can read profiles" on public.profiles;
create policy "Users and admins can read profiles"
    on public.profiles for select to authenticated
    using ((select auth.uid()) = user_id or (select public.is_admin()));

drop policy if exists "Users can create their own profile" on public.profiles;
create policy "Users can create their own profile"
    on public.profiles for insert to authenticated
    with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
    on public.profiles for update to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

drop policy if exists "Users and admins can read roles" on public.user_roles;
create policy "Users and admins can read roles"
    on public.user_roles for select to authenticated
    using ((select auth.uid()) = user_id or (select public.is_admin()));

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    profile_name text := coalesce(new.raw_user_meta_data ->> 'name', '');
    profile_username text := nullif(btrim(new.raw_user_meta_data ->> 'username'), '');
begin
    insert into public.profiles (user_id, display_name, username, email)
    values (new.id, profile_name, profile_username, new.email);
    return new;
exception
    when unique_violation then
        insert into public.profiles (user_id, display_name, email)
        values (new.id, profile_name, new.email);
        return new;
end;
$$;

drop trigger if exists create_profile_after_signup on auth.users;
create trigger create_profile_after_signup
    after insert on auth.users
    for each row execute function public.create_profile_for_new_user();

insert into public.profiles (user_id, display_name, email)
select
    id,
    coalesce(raw_user_meta_data ->> 'name', ''),
    email
from auth.users
on conflict (user_id) do nothing;
