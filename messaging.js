(() => {
    const photoFallback = "https://images.unsplash.com/photo-1534522341644-576f6eac6c10?auto=format&fit=crop&w=120&q=85";
    const stickerOptions = ["❤️", "😂", "👋", "🥰", "🎉", "👍", "🤔", "✨", "😎", "🙌", "😭", "🔥"];
    const privateChatsElement = document.getElementById("private-conversations");
    const groupChatsElement = document.getElementById("group-conversations");
    const chatBody = document.getElementById("chat-body");
    const personHeader = document.getElementById("person-header");
    const profilePanel = document.getElementById("profile");
    const chatSearch = document.getElementById("search");
    const profileDialog = document.getElementById("member-dialog");
    const addPeopleDialog = document.getElementById("add-people-dialog");
    const mediaPicker = document.getElementById("chat-attachment");
    const stickerPicker = document.getElementById("sticker-picker");
    let client = null;
    let signedInUser = null;
    let chatRows = [];
    let activeChatId = null;
    let activeMembers = [];
    let directoryProfiles = [];
    let directoryCursor = null;
    let directoryHasMore = false;
    let directoryRequest = 0;
    let directorySearchTimer = null;
    let selectedProfile = null;
    let realtimeChannel = null;

    const escapeHTML = value => String(value ?? "").replace(/[&<>"']/g, character => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[character]));

    function currentChat() {
        return chatRows.find(chat => chat.conversation_id === activeChatId);
    }

    function showStatus(element, message, isError = false) {
        element.classList.toggle("error", isError);
        element.textContent = message;
    }

    function renderInbox() {
        const query = chatSearch.value.trim().toLocaleLowerCase();
        const filtered = chatRows.filter(chat =>
            `${chat.title || ""} ${chat.participant_names || ""} ${chat.latest_message || ""}`.toLocaleLowerCase().includes(query)
        );
        document.getElementById("match-count").textContent = `${chatRows.length} chat${chatRows.length === 1 ? "" : "s"}`;
        const privateChats = filtered.filter(chat => chat.chat_type === "private");
        const groupChats = filtered.filter(chat => chat.chat_type === "group");
        document.getElementById("private-chat-count").textContent = String(privateChats.length);
        document.getElementById("group-chat-count").textContent = String(groupChats.length);

        const renderSection = (element, chats, type) => {
            if (!chats.length) {
                const message = query
                    ? "No chats match your search."
                    : type === "private"
                        ? "Private chats with one other person will show here."
                        : "Groups you create or join will show here.";
                element.innerHTML = `<div class="empty-search">${message}</div>`;
                return;
            }
            element.innerHTML = chats.map(chat => `
                <button class="conversation ${chat.conversation_id === activeChatId ? "active" : ""}" type="button" data-chat-id="${escapeHTML(chat.conversation_id)}">
                    <span class="avatar-wrap"><img class="avatar" src="${escapeHTML(chat.photo_url || photoFallback)}" alt=""></span>
                    <span class="conversation-copy"><span class="conversation-top"><span class="conversation-name">${escapeHTML(chat.title || chat.participant_names || "Chat")}</span><span class="time">${chat.latest_at ? escapeHTML(new Date(chat.latest_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })) : ""}</span></span><span class="preview">${escapeHTML(chat.latest_message || `${chat.member_count} members · Start a conversation`)}</span></span>
                </button>`).join("");
        };
        renderSection(privateChatsElement, privateChats, "private");
        renderSection(groupChatsElement, groupChats, "group");
    }

    function renderEmptyChat() {
        activeMembers = [];
        personHeader.innerHTML = '<span class="person-name">Your chats</span>';
        chatBody.innerHTML = '<div class="chat-empty">Choose someone in any level and select <strong>Add to chat</strong>.<br>Your conversations and messages will stay here.</div>';
        profilePanel.innerHTML = '<div class="profile-top"><span>Chat details</span></div><p class="bio" style="padding:0 21px">Pick a chat to see its members and invite more people.</p>';
        document.getElementById("add-chat-people").disabled = true;
        document.getElementById("block-chat-user").hidden = true;
    }

    async function signMediaPath(path) {
        if (!path) return "";
        const { data, error } = await client.storage.from("chat-media").createSignedUrl(path, 60 * 60);
        if (error) throw error;
        return data.signedUrl;
    }

    async function loadConversation(chatId) {
        const switchingChat = activeChatId !== chatId;
        activeChatId = chatId;
        renderInbox();
        if (switchingChat) {
            chatBody.innerHTML = '<div class="chat-empty">Loading messages…</div>';
            profilePanel.innerHTML = '<div class="profile-top"><span>Chat members</span></div>';
        }
        try {
            const [memberResult, messageResult] = await Promise.all([
                client.rpc("get_conversation_members", { chat_id: chatId }),
                client.rpc("get_conversation_messages", { chat_id: chatId })
            ]);
            if (memberResult.error) throw memberResult.error;
            if (messageResult.error) throw messageResult.error;
            if (activeChatId !== chatId) return;
            activeMembers = memberResult.data || [];
            const chat = currentChat();
            const chatName = chat?.title || chat?.participant_names || "Chat";
            personHeader.innerHTML = `
                <div><span class="person-name">${escapeHTML(chatName)}</span><span class="person-status"><i></i>${activeMembers.length} member${activeMembers.length === 1 ? "" : "s"}</span></div>`;

            const otherMembers = activeMembers.filter(member => member.user_id !== signedInUser.id);
            const directMember = activeMembers.length === 2 ? otherMembers[0] : null;
            document.getElementById("add-chat-people").disabled = false;
            document.getElementById("block-chat-user").hidden = !directMember;
            document.getElementById("block-chat-user").dataset.blockUser = directMember?.user_id || "";

            const rendered = await Promise.all((messageResult.data || []).map(async message => {
                const isMine = message.sender_id === signedInUser.id;
                let content;
                if (message.message_type === "image" || message.message_type === "video") {
                    const mediaUrl = await signMediaPath(message.media_path);
                    content = message.message_type === "image"
                        ? `<a href="${escapeHTML(mediaUrl)}" target="_blank" rel="noopener"><img class="message-attachment" src="${escapeHTML(mediaUrl)}" alt="Shared photo" loading="lazy"></a>`
                        : `<video class="message-attachment" src="${escapeHTML(mediaUrl)}" controls playsinline preload="metadata"></video>`;
                } else {
                    content = `<div class="${message.message_type === "sticker" ? "message-sticker" : "bubble"}">${escapeHTML(message.body)}</div>`;
                }
                return `<div class="message-row ${isMine ? "outgoing" : "incoming"}">
                    ${!isMine ? `<img class="message-avatar" src="${escapeHTML(message.sender_photo_url || photoFallback)}" alt="">` : ""}
                    <div class="message-content">${!isMine && activeMembers.length > 2 ? `<span class="message-sender">${escapeHTML(message.sender_name || "Member")}</span>` : ""}${content}<div class="message-meta">${isMine ? "You" : escapeHTML(message.sender_name || "Member")} · ${escapeHTML(new Date(message.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }))}</div></div>
                </div>`;
            }));
            if (activeChatId !== chatId) return;
            chatBody.innerHTML = `<div class="day-divider">MESSAGES</div>${rendered.join("") || '<div class="chat-empty">Say hello to start the conversation.</div>'}<div id="message-end"></div>`;
            chatBody.scrollTop = chatBody.scrollHeight;
            const visibleMembers = activeMembers.map(member => `
                <div class="chat-profile-member"><img src="${escapeHTML(member.photo_url || photoFallback)}" alt=""><span>${escapeHTML(member.display_name || "Sway member")} · ${escapeHTML(member.level || "Level not set")}</span>${member.user_id !== signedInUser.id ? `<button type="button" data-block-member="${escapeHTML(member.user_id)}">Block</button>` : "<small>You</small>"}</div>`).join("");
            profilePanel.innerHTML = `<div class="profile-top"><span>Chat members</span></div><div style="padding:0 15px">${visibleMembers}</div>`;
        } catch (error) {
            showToast(error.message || "Could not load this conversation.");
        }
    }

    async function refreshChatList() {
        const { data, error } = await client.rpc("list_my_conversations");
        if (error) throw error;
        chatRows = data || [];
        if (activeChatId && !chatRows.some(chat => chat.conversation_id === activeChatId)) activeChatId = null;
        renderInbox();
        if (activeChatId) await loadConversation(activeChatId);
        else renderEmptyChat();
    }

    async function openProfile(person) {
        selectedProfile = person;
        document.getElementById("member-dialog-photo").src = person.photo_url || photoFallback;
        document.getElementById("member-dialog-photo").alt = person.display_name || "Sway member";
        document.getElementById("member-dialog-name").textContent = `${person.display_name || "Sway member"}${person.age ? `, ${person.age}` : ""}`;
        document.getElementById("member-dialog-level").textContent = `${person.level || "Level not set"} level`;
        document.getElementById("member-dialog-block").disabled = false;
        if (!profileDialog.open) profileDialog.showModal();
    }

    function renderAddPeople(filter = "") {
        const blockedAndActive = new Set(activeMembers.map(member => member.user_id));
        const normalized = filter.trim().toLocaleLowerCase();
        const results = directoryProfiles.filter(person =>
            !blockedAndActive.has(person.user_id)
            && `${person.display_name || ""} ${person.level || ""}`.toLocaleLowerCase().includes(normalized)
        );
        const grid = document.getElementById("all-members-grid");
        grid.innerHTML = results.map(person => `
            <article class="member-card">
                <img class="member-photo" src="${escapeHTML(person.photo_url || photoFallback)}" alt="${escapeHTML(person.display_name || "Member")}" loading="lazy">
                <div class="member-card-copy"><h2>${escapeHTML(person.display_name || "Sway member")}</h2><p class="member-level">${escapeHTML(person.level || "—")} level</p><button class="flow-button primary" type="button" data-add-member="${escapeHTML(person.user_id)}">Add to this chat</button></div>
            </article>`).join("");
        document.getElementById("load-more-chat-members").hidden = !directoryHasMore;
        showStatus(document.getElementById("add-people-status"), results.length ? "" : directoryHasMore ? "No more available members on this page." : "No available members found.");
    }

    async function openAddPeople() {
        if (!activeChatId) {
            showToast("Choose a chat first, or add someone from their profile.");
            return;
        }
        showStatus(document.getElementById("add-people-status"), "Finding people across all levels…");
        document.getElementById("all-members-grid").replaceChildren();
        document.getElementById("all-members-search").value = "";
        directoryProfiles = [];
        directoryCursor = null;
        directoryHasMore = false;
        directoryRequest++;
        clearTimeout(directorySearchTimer);
        addPeopleDialog.showModal();
        await loadMoreAddPeople(false);
    }

    async function loadMoreAddPeople(append = true) {
        const requestId = directoryRequest;
        const { data, error } = await client.rpc("browse_profiles", {
            requested_level: "all",
            older_than: directoryCursor?.created_at || null,
            before_user: directoryCursor?.user_id || null,
            result_limit: 48,
            search_text: document.getElementById("all-members-search").value.trim() || null
        });
        if (requestId !== directoryRequest) return;
        if (error) {
            showStatus(document.getElementById("add-people-status"), error.message || "Could not find members.", true);
            return;
        }
        directoryProfiles = append ? [...directoryProfiles, ...(data || [])] : data || [];
        directoryCursor = data?.length === 48 ? data[data.length - 1] : null;
        directoryHasMore = Boolean(directoryCursor);
        renderAddPeople(document.getElementById("all-members-search").value);
    }

    function searchAddPeople(query) {
        directoryRequest++;
        clearTimeout(directorySearchTimer);
        directoryProfiles = [];
        directoryCursor = null;
        directoryHasMore = false;
        renderAddPeople(query);
        showStatus(document.getElementById("add-people-status"), "Searching all levels…");
        directorySearchTimer = setTimeout(() => {
            loadMoreAddPeople(false).catch(error => showStatus(document.getElementById("add-people-status"), error.message || "Could not search members.", true));
        }, 250);
    }

    async function blockUser(userId) {
        if (!userId || !window.confirm("Block this user? You will no longer be able to chat with them or access a shared group chat.")) return;
        const { error } = await client.rpc("block_user", { target_user: userId });
        if (error) throw error;
        directoryProfiles = directoryProfiles.filter(person => person.user_id !== userId);
        matchedProfiles = matchedProfiles.filter(person => person.user_id !== userId);
        if (!membersScreen.hidden) renderMemberCards();
        if (profileDialog.open) profileDialog.close();
        showToast("User blocked.");
        await refreshChatList();
    }

    async function insertMessage(messageType, body = "", mediaPath = null) {
        if (!activeChatId) {
            showToast("Choose or add someone to a chat first.");
            return;
        }
        const { error } = await client.from("messages").insert({
            conversation_id: activeChatId,
            sender_id: signedInUser.id,
            message_type: messageType,
            body: body || null,
            media_path: mediaPath
        });
        if (error) throw error;
        await refreshChatList();
    }

    async function sendAttachments(files) {
        if (!activeChatId) throw new Error("Choose or add someone to a chat first.");
        for (const file of files) {
            const messageType = file.type.startsWith("image/") ? "image" : file.type.startsWith("video/") ? "video" : "";
            if (!messageType || !["image/jpeg", "image/png", "image/webp", "image/gif", "video/mp4", "video/webm"].includes(file.type)) {
                throw new Error("Choose a JPEG, PNG, WebP, GIF, MP4, or WebM file.");
            }
            if (file.size > 25 * 1024 * 1024) throw new Error("Each photo or video must be 25 MB or smaller.");
            const extension = file.name.split(".").pop().toLocaleLowerCase().replace(/[^a-z0-9]/g, "");
            const path = `${activeChatId}/${signedInUser.id}/${crypto.randomUUID()}.${extension}`;
            const { error: uploadError } = await client.storage.from("chat-media").upload(path, file, { contentType: file.type, upsert: false });
            if (uploadError) throw uploadError;
            await insertMessage(messageType, "", path);
        }
    }

    function subscribeToChatUpdates() {
        if (realtimeChannel) client.removeChannel(realtimeChannel);
        realtimeChannel = client.channel(`sway-chat-${signedInUser.id}`)
            .on("postgres_changes", { event: "*", schema: "public", table: "messages" }, () => {
                refreshChatList().catch(error => showToast(error.message || "Could not refresh chats."));
            })
            .on("postgres_changes", { event: "*", schema: "public", table: "conversation_members" }, () => {
                refreshChatList().catch(error => showToast(error.message || "Could not refresh chat members."));
            })
            .on("postgres_changes", { event: "*", schema: "public", table: "user_blocks" }, () => {
                refreshChatList().catch(error => showToast(error.message || "Could not refresh blocked chats."));
            })
            .subscribe(status => {
                if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
                    showToast("Live chat updates disconnected. Refresh the page to reconnect.");
                }
            });
    }

    function initialize(supabase, user) {
        if (signedInUser?.id === user.id && client === supabase) return refreshChatList();
        if (realtimeChannel && client) client.removeChannel(realtimeChannel);
        client = supabase;
        signedInUser = user;
        activeChatId = null;
        chatRows = [];
        people.splice(0, people.length);
        renderInbox();
        renderEmptyChat();
        subscribeToChatUpdates();
        return refreshChatList();
    }

    function clear() {
        if (realtimeChannel && client) client.removeChannel(realtimeChannel);
        realtimeChannel = null;
        client = null;
        signedInUser = null;
        chatRows = [];
        activeChatId = null;
        directoryProfiles = [];
        selectedProfile = null;
        renderInbox();
        renderEmptyChat();
    }

    document.addEventListener("click", async event => {
        const closeDialog = event.target.closest("[data-close-dialog]");
        if (closeDialog) {
            closeDialog.closest("dialog").close();
            return;
        }
        const chatButton = event.target.closest("[data-chat-id]");
        if (chatButton && signedInUser) {
            await loadConversation(chatButton.dataset.chatId);
            return;
        }
        const addMemberButton = event.target.closest("[data-add-member]");
        if (addMemberButton && signedInUser) {
            const person = directoryProfiles.find(profile => profile.user_id === addMemberButton.dataset.addMember);
            if (!person || !activeChatId) return;
            try {
                const { data: destinationChatId, error } = await client.rpc("add_user_to_conversation", {
                    chat_id: activeChatId,
                    target_user: person.user_id
                });
                if (error) throw error;
                if (!destinationChatId) throw new Error("The chat was updated, but its conversation could not be opened.");
                const createdGroup = destinationChatId !== activeChatId;
                showToast(createdGroup
                    ? `A group chat with ${person.display_name || "this user"} was created.`
                    : `${person.display_name || "User"} added to the group.`);
                await refreshChatList();
                await loadConversation(destinationChatId);
                if (createdGroup) addPeopleDialog.close();
                renderAddPeople(document.getElementById("all-members-search").value);
            } catch (error) {
                showStatus(document.getElementById("add-people-status"), error.message || "Could not add this user.", true);
            }
            return;
        }
        const blockMember = event.target.closest("[data-block-member]");
        if (blockMember && signedInUser) {
            try {
                await blockUser(blockMember.dataset.blockMember);
            } catch (error) {
                showToast(error.message || "Could not block this user.");
            }
            return;
        }
        if (event.target.closest("#add-chat-people") && signedInUser) {
            openAddPeople().catch(error => showToast(error.message || "Could not open the member list."));
            return;
        }
        if (event.target.closest("#new-chat-button") && signedInUser) {
            showScreen("levels");
            return;
        }
        if (event.target.closest("#load-more-chat-members") && signedInUser) {
            const button = event.target.closest("#load-more-chat-members");
            button.disabled = true;
            loadMoreAddPeople().catch(error => showStatus(document.getElementById("add-people-status"), error.message || "Could not load more members.", true))
                .finally(() => { button.disabled = false; });
            return;
        }
        if (event.target.closest("#block-chat-user") && signedInUser) {
            try {
                await blockUser(event.target.closest("#block-chat-user").dataset.blockUser);
            } catch (error) {
                showToast(error.message || "Could not block this user.");
            }
            return;
        }
        if (event.target.closest("#attach-chat-media") && signedInUser) {
            mediaPicker.click();
            return;
        }
        if (event.target.closest("#heart-button") && signedInUser) {
            stickerPicker.hidden = !stickerPicker.hidden;
            return;
        }
        const stickerButton = event.target.closest("[data-sticker]");
        if (stickerButton && signedInUser) {
            insertMessage("sticker", stickerButton.dataset.sticker).catch(error => showToast(error.message || "Could not send sticker."));
            stickerPicker.hidden = true;
            return;
        }
        if (event.target.closest("#member-dialog-add") && signedInUser && selectedProfile) {
            const button = event.target.closest("#member-dialog-add");
            button.disabled = true;
            try {
                const { data, error } = await client.rpc("start_direct_chat", { target_user: selectedProfile.user_id });
                if (error) throw error;
                profileDialog.close();
                await refreshChatList();
                await loadConversation(data);
                showScreen("chat");
            } catch (error) {
                showToast(error.message || "Could not add this user to chat.");
            } finally {
                button.disabled = false;
            }
            return;
        }
        if (event.target.closest("#member-dialog-block") && signedInUser && selectedProfile) {
            try {
                await blockUser(selectedProfile.user_id);
            } catch (error) {
                showToast(error.message || "Could not block this user.");
            }
        }
    });

    document.getElementById("composer").addEventListener("submit", async event => {
        if (!signedInUser) return;
        event.preventDefault();
        const input = document.getElementById("message-input");
        const text = input.value.trim();
        if (!text) return;
        try {
            await insertMessage("text", text);
            input.value = "";
            input.focus();
        } catch (error) {
            showToast(error.message || "Could not send this message.");
        }
    });

    mediaPicker.addEventListener("change", async () => {
        try {
            if (mediaPicker.files.length) await sendAttachments(Array.from(mediaPicker.files));
        } catch (error) {
            showToast(error.message || "Could not send this media.");
        } finally {
            mediaPicker.value = "";
        }
    });

    document.getElementById("all-members-search").addEventListener("input", event => searchAddPeople(event.currentTarget.value));
    chatSearch.addEventListener("input", () => {
        if (signedInUser) renderInbox();
    });
    document.getElementById("sticker-picker").innerHTML = stickerOptions.map(sticker =>
        `<button class="sticker-choice" type="button" data-sticker="${escapeHTML(sticker)}" aria-label="Send sticker ${escapeHTML(sticker)}">${escapeHTML(sticker)}</button>`
    ).join("");
    document.querySelector(".composer-hint").textContent = "Photos, videos and stickers are welcome. Screenshots are handled privately by your device.";

    window.SwayMessaging = { initialize, openProfile, clear };
})();
