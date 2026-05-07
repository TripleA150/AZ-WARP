// AZ-WARP Web Panel - клиентские скрипты

// ===== Конфигурация Tailwind (тёмно-зелёная палитра) =====
if (typeof tailwind !== 'undefined') {
    tailwind.config = {
        darkMode: 'class',
        theme: {
            extend: {
                colors: {
                    brand: {
                        50:  '#ecfdf5',
                        100: '#d1fae5',
                        200: '#a7f3d0',
                        300: '#6ee7b7',
                        400: '#34d399',
                        500: '#10b981',
                        600: '#059669',
                        700: '#047857',
                        800: '#065f46',
                        900: '#064e3b',
                        950: '#022c22',
                    },
                    surface: {
                        50:  '#f0fdf4',
                        900: '#0a1410',
                        950: '#050a08',
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

// ===== Toast-уведомления (через HX-Trigger) =====

function showToast(message, category = 'info') {
    const container = document.getElementById('toast-container');
    if (!container) return;

    const colors = {
        success: 'bg-emerald-700 border-emerald-500',
        error:   'bg-red-700 border-red-500',
        warning: 'bg-amber-700 border-amber-500',
        info:    'bg-slate-700 border-slate-500',
    };

    const icons = {
        success: '✓',
        error:   '✕',
        warning: '!',
        info:    'ℹ',
    };

    const toast = document.createElement('div');
    toast.className = `${colors[category] || colors.info} text-white px-4 py-3 rounded-lg shadow-lg border-l-4 flex items-start gap-3 min-w-[280px] max-w-md transform transition-all duration-300 translate-x-full opacity-0`;

    toast.innerHTML = `
        <span class="text-xl font-bold flex-shrink-0">${icons[category] || icons.info}</span>
        <span class="flex-1 text-sm leading-snug">${escapeHtml(message)}</span>
        <button class="text-white/70 hover:text-white flex-shrink-0" onclick="this.parentElement.remove()">×</button>
    `;

    container.appendChild(toast);

    // Анимация появления
    requestAnimationFrame(() => {
        toast.classList.remove('translate-x-full', 'opacity-0');
    });

    // Авто-удаление
    setTimeout(() => {
        toast.classList.add('translate-x-full', 'opacity-0');
        setTimeout(() => toast.remove(), 300);
    }, 4000);
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// ===== Слушатели HX-Trigger =====

document.body.addEventListener('showToast', function(evt) {
    const { message, category } = evt.detail;
    showToast(message, category);
});

// ===== Триггеры обновления секций =====
// HTMX автоматически вызовет hx-trigger="refreshXxx from:body" в нужных элементах

// ===== Подтверждение опасных действий =====

document.addEventListener('htmx:confirm', function(evt) {
    const confirmText = evt.detail.elt.getAttribute('data-confirm');
    if (confirmText) {
        evt.preventDefault();
        if (window.confirm(confirmText)) {
            evt.detail.issueRequest();
        }
    }
});

// ===== Управление модальными окнами =====

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

// Закрытие по клику на фон
document.addEventListener('click', function(e) {
    if (e.target.classList.contains('modal-backdrop')) {
        const modal = e.target.closest('[id^="modal-"]');
        if (modal) closeModal(modal.id);
    }
});

// Закрытие по Escape
document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') {
        document.querySelectorAll('[id^="modal-"]:not(.hidden)').forEach(m => {
            closeModal(m.id);
        });
    }
});

// ===== Sidebar toggle на мобильных =====

function toggleSidebar() {
    const sidebar = document.getElementById('sidebar');
    const backdrop = document.getElementById('sidebar-backdrop');
    if (sidebar && backdrop) {
        sidebar.classList.toggle('-translate-x-full');
        backdrop.classList.toggle('hidden');
    }
}
