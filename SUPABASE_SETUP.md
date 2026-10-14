# Supabase admin setup

This adds Supabase-backed user profiles and a shared level-based member directory, with private real-time direct/group chats, blocking, and photo/video/sticker messages. It also includes a Supabase-authenticated admin dashboard and database-enforced access controls. Earlier localStorage demo accounts are not automatically migrated and remain local to their browser.

## 1. Create the Supabase project

Create a project at [supabase.com](https://supabase.com). In **Project Settings → API**, copy the project URL and the publishable key (or legacy `anon` key). In `index.html`, replace:

- `YOUR_SUPABASE_PROJECT_URL` with the project URL
- `YOUR_SUPABASE_PUBLISHABLE_KEY` with the publishable/anon key

These browser values are public by design. Never put a `service_role` or secret key in `index.html`.

## 2. Create the protected tables

Open **SQL Editor** in the Supabase dashboard and run [`supabase/schema.sql`](./supabase/schema.sql). It can be rerun to apply updates. The script creates profiles, chat tables and roles, enables row-level security, installs a trigger that creates a profile when a Supabase Auth user registers, and adds protected presence, directory and chat functions. It also creates a public `profile-photos` bucket and a private `chat-media` bucket; realtime is enabled for messages, membership changes and blocks.

## 3. Create and authorize the administrator

In **Authentication → Users**, create or invite your own admin account and set its password privately in Supabase. Do not put the password in this site or in SQL. Confirm the email first, then replace `YOUR_ADMIN_EMAIL` in this SQL with that account's email before running it in SQL Editor:

```sql
do $$
declare
    admin_user_id uuid;
begin
    select id into admin_user_id
    from auth.users
    where lower(email) = lower('YOUR_ADMIN_EMAIL')
      and email_confirmed_at is not null;

    if admin_user_id is null then
        raise exception 'Confirmed Supabase Auth user YOUR_ADMIN_EMAIL was not found';
    end if;

    insert into public.user_roles (user_id, role)
    values (admin_user_id, 'admin')
    on conflict (user_id, role) do nothing;
end;
$$;
```

Role changes must be made by a trusted operator in the Supabase dashboard or a separately secured server. Do not add admin-role assignment to a client-side form or expose service credentials. If this admin email should change, replace it in the SQL before running it.

## 4. Sign up, sign in, and find your level

Serve the site over HTTP(S) and sign in with the administrator's email and Supabase Auth password using the normal **Log in** form (or open `#admin`). After Supabase confirms the account has the `admin` role, the site offers **Admin dashboard** and **User site**. Other Supabase users are sent to the user site and never see the admin choice. The dashboard is not linked from the normal user interface. Its profile query is independently restricted by RLS, so bypassing the page check does not grant access to profile data.

New users sign up through Supabase Auth and complete a profile with a photo, name, and level. Profile photos are resized in the browser and uploaded to the public `profile-photos` bucket. After sign-in, users can choose any level, view profiles, and select **Add to chat**. The inbox keeps one-to-one private chats and multi-member groups in separate lists. Adding someone to a private chat preserves that private chat and creates a separate group with its existing members and the invitee; adding someone to a group adds them to that group. Any group member can invite users from any level. There is no application-imposed member or chat count cap. Text and sticker messages are stored in Supabase and update in real time. Users can send JPEG, PNG, WebP, GIF, MP4 or WebM attachments up to 25 MB each; these are stored privately and only chat participants can access them. Blocking a participant prevents access to chats they share with the blocker and prevents new messages or invitations between them.

The level lookup returns only a member's ID, display name, age, level, and photo URL; it does not expose email addresses. Row Level Security continues to let regular accounts read only their own profile rows, while admins can read all profiles. Signed-in users send a heartbeat while the page is visible; a user is considered offline once the heartbeat is older than five minutes. Screenshots are ordinary device/browser actions; the site does not detect screenshots or send screenshot notifications.

Accounts created by the earlier browser-only demo remain in that browser's `localStorage`; they are not automatically migrated or visible in the shared directory. They must create a Supabase account to find people in their level.
