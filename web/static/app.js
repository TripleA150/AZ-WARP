// AZ-WARP Web Panel - клиентские скрипты

// ===== Конфигурация Tailwind =====
if (typeof tailwind !== 'undefined') {
    tailwind.config = {
        darkMode: 'class',
        theme: {
            extend: {
                colors: {
                    brand: {
                        50: '#ecfdf5', 100: '#d1fae5', 200: '#a7f3d0',
                        300: '#6ee7b7', 400: '#34d399', 500: '#10b981',
                        600: '#059669', 700: '#047857', 800: '#065f46',
                        900: '#064e3b', 950: '#022c22',
                    },
                    surface: {
                        50: '#f0fdf4', 900: '#0a1410', 950: '#050a08',
                    }
                },
                fontFamily: {
                    sans: ['Inter', 'system-ui', '-apple-system', 'sans-serif'],
                    mono: ['"JetBrains Mono"', 'Consolas', 'Monaco', 'monospace'],
                }
            }
        }
    };
}

// ===== Toast =====

function showToast(message, category) {
    category = category || 'info';
    const container = document.getElementById('toast-container');
    if (!container) {
        console.warn('toast container not found, falling back to alert:', message);
        return;
    }

    const colors = {
        success: 'bg-emerald-700 border-emerald-400',
        error:   'bg-red-700 border-red-400',
        warning: 'bg-amber-700 border-amber-400',
        info:    'bg-slate-700 border-slate-400',
    };
    const icons = { success: '✓', error: '✕', warning: '!', info: 'ℹ' };

    const toast = document.createElement('div');
    toast.className = (colors[category] || colors.info) +
        ' text-white px-4 py-3 rounded-lg shadow-2xl border-l-4 flex items-start gap-3 ' +
        'min-w-[280px] max-w-md transform transition-all duration-300 translate-x-full opacity-0';

    const iconSpan = document.createElement('span');
    iconSpan.className = 'text-xl font-bold flex-shrink-0';
    iconSpan.textContent = icons[category] || icons.info;

    const msgSpan = document.createElement('span');
    msgSpan.className = 'flex-1 text-sm leading-snug break-words';
    msgSpan.textContent = message;

    const closeBtn = document.createElement('button');
    closeBtn.className = 'text-white/70 hover:text-white flex-shrink-0 text-lg leading-none';
    closeBtn.textContent = '×';
    closeBtn.onclick = function() { toast.remove(); };

    toast.appendChild(iconSpan);
    toast.appendChild(msgSpan);
    toast.appendChild(closeBtn);
    container.appendChild(toast);

    requestAnimationFrame(function() {
        toast.classList.remove('translate-x-full', 'opacity-0');
    });

    setTimeout(function() {
        toast.classList.add('translate-x-full', 'opacity-0');
        setTimeout(function() { toast.remove(); }, 300);
    }, 4500);
}

// ===== Модальные окна =====

function openModal(id) {
    const modal = document.getElementById(id);
    if (modal) {
        modal.classList.remove('hidden');
        modal.classList.add('flex');
        document.body.style.overflow = 'hidden';
    }
}

function closeModal(id) {
    const modal = document.getElementById(id);
    if (modal) {
        modal.classList.add('hidden');
        modal.classList.remove('flex');
        document.body.style.overflow = '';
    }
}

// ===== Sidebar mobile =====

function toggleSidebar() {
    const sidebar = document.getElementById('sidebar');
    const backdrop = document.getElementById('sidebar-backdrop');
    if (sidebar && backdrop) {
        sidebar.classList.toggle('-translate-x-full');
        backdrop.classList.toggle('hidden');
    }
}

// ===== Обработчики после загрузки DOM =====

function initEventHandlers() {
    if (!document.body) {
        // на всякий случай
        setTimeout(initEventHandlers, 50);
        return;
    }

    // Toast через HX-Trigger
    document.body.addEventListener('showToast', function(evt) {
        const detail = evt.detail || {};
        // HTMX 2.x при JSON-объекте кладёт его прямо в evt.detail
        const message = detail.message || (detail.value && detail.value.message) || 'Готово';
        const category = detail.category || (detail.value && detail.value.category) || 'info';
        showToast(message, category);
    });

    // Подтверждение действий через data-confirm
    document.body.addEventListener('htmx:confirm', function(evt) {
        const elt = evt.detail.elt;
        const txt = elt && elt.getAttribute && elt.getAttribute('data-confirm');
        if (txt) {
            evt.preventDefault();
            if (window.confirm(txt)) {
                evt.detail.issueRequest(true);
            }
        }
    });

    // Закрытие модалок по фону
    document.body.addEventListener('click', function(e) {
        const t = e.target;
        if (t && t.classList && t.classList.contains('modal-backdrop')) {
            const modal = t.closest('[id^="modal-"]');
            if (modal) closeModal(modal.id);
        }
    });

    // Escape для модалок
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') {
            const open = document.querySelectorAll('[id^="modal-"]:not(.hidden)');
            open.forEach(function(m) { closeModal(m.id); });
        }
    });

    // Глобальный индикатор загрузки HTMX
    document.body.addEventListener('htmx:beforeRequest', function() {
        const l = document.getElementById('global-loader');
        if (l) l.classList.add('htmx-request');
    });
    document.body.addEventListener('htmx:afterRequest', function() {
        const l = document.getElementById('global-loader');
        if (l) l.classList.remove('htmx-request');
    });

    // Если HTMX вернул ошибку сети
    document.body.addEventListener('htmx:responseError', function(evt) {
        showToast('Ошибка сервера: ' + (evt.detail.xhr.status || 'неизвестно'), 'error');
    });
    document.body.addEventListener('htmx:sendError', function() {
        showToast('Не удалось связаться с сервером', 'error');
    });
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initEventHandlers);
} else {
    initEventHandlers();
}
