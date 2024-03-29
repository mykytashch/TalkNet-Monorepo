#!/bin/bash

# Установка строгого режима выполнения скрипта
set -euo pipefail

# Определение функции для обработки непредвиденных ошибок
trap "echo 'Error: Script failed.'" ERR

# Вывод начального сообщения о начале процесса
echo "Начало полной очистки, обновления и восстановления проекта: $(date)"

# Определение основных переменных для конфигурации
APP_DIR="/srv/talknet/backend/auth-service"  # Путь к директории приложения
VENV_DIR="$APP_DIR/venv"  # Путь к виртуальной среде Python
LOG_DIR="/var/log/talknet"  # Директория для логов
BACKUP_DIR="/srv/talknet/backups"  # Директория для бэкапов базы данных
REQS_BACKUP_DIR="/tmp"  # Временная директория для сохранения requirements.txt
PG_DB="prod_db"  # Имя базы данных PostgreSQL
LOG_FILE="$LOG_DIR/update-$(date +%Y-%m-%d_%H-%M-%S).log"  # Файл для записи лога текущего процесса обновления
REPO_URL="https://github.com/mykytashch/TalkNet-Monorepo"  # URL Git репозитория
MAX_ATTEMPTS=3  # Максимальное количество попыток для операций, требующих повторения
ATTEMPT=1  # Начальное значение счетчика попыток

# Функция для создания бэкапа базы данных
create_database_backup() {
    echo "Создание бэкапа базы данных..."
    mkdir -p "$BACKUP_DIR"
    sudo -u postgres pg_dump "$PG_DB" > "$BACKUP_DIR/db_backup_$(date +%Y-%m-%d_%H-%M-%S).sql"
}

# Функция для очистки текущей установки с сохранением важных файлов
cleanup() {
    echo "Очистка текущей установки..."
    if [ -f "$APP_DIR/requirements.txt" ]; then
        echo "Сохранение файла requirements.txt..."
        cp "$APP_DIR/requirements.txt" "$REQS_BACKUP_DIR"
    fi
    if [ -f "$APP_DIR/app.py" ]; then
        echo "Сохранение файла app.py..."
        cp "$APP_DIR/app.py" "$REQS_BACKUP_DIR"
    fi
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"
}

# Функция для клонирования репозитория и установки зависимостей
setup() {
    echo "Клонирование репозитория и установка зависимостей..."
    git clone "$REPO_URL" "$APP_DIR"
    cd "$APP_DIR"
    if [ -f "$REQS_BACKUP_DIR/requirements.txt" ]; then
        echo "Восстановление файла requirements.txt..."
        cp "$REQS_BACKUP_DIR/requirements.txt" "$APP_DIR"
    fi
    if [ -f "$REQS_BACKUP_DIR/app.py" ]; then
        echo "Восстановление файла app.py..."
        cp "$REQS_BACKUP_DIR/app.py" "$APP_DIR"
    fi
    python3 -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip
    if [ -f "$APP_DIR/requirements.txt" ]; then
        pip install -r "$APP_DIR/requirements.txt"
    else
        echo "Файл requirements.txt не найден. Продолжение без установки зависимостей."
    fi
}

# Функция для восстановления базы данных (опционально)
restore_database() {
    echo "Восстановление базы данных..."
    # Здесь должен быть код для восстановления базы данных из бэкапа
}

# Функция для получения обновлений из репозитория
update_repository() {
    echo "Получение обновлений из репозитория..."
    cd "$APP_DIR"
    if git pull; then
        echo "Репозиторий успешно обновлен."
    else
        echo "Ошибка при обновлении репозитория. Попытка восстановления..."
        git fetch --all
        git reset --hard origin/main
        echo "Репозиторий восстановлен."
    fi
}

# Функция для активации виртуального окружения
activate_virtualenv() {
    echo "Активация виртуального окружения..."
    if [ -d "$VENV_DIR" ]; then
        source "$VENV_DIR/bin/activate"
    else
        echo "Виртуальное окружение не найдено. Создание..."
        python3 -m venv "$VENV_DIR"
        source "$VENV_DIR/bin/activate"
        python -m ensurepip --upgrade
    fi
}

# Функция для установки пакетов Python
install_python_packages() {
    echo "Установка пакетов Python..."
    if pip install --upgrade pip && [ -f "$APP_DIR/requirements.txt" ]; then
        pip install --upgrade -r "$APP_DIR/requirements.txt"
        pip install Flask-Cors  # Дополнительная установка Flask-Cors
        echo "Зависимости Python успешно обновлены."
    else
        echo "Ошибка при обновлении зависимостей Python. Попытка установки снова..."
        pip install --upgrade pip
        pip install --upgrade -r "$APP_DIR/requirements.txt"
        pip install Flask-Cors  # Дополнительная установка Flask-Cors
    fi
}

# Функция для выполнения миграции базы данных
run_database_migration() {
    while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
        echo "Попытка $ATTEMPT миграции базы данных..."
        export FLASK_APP=app.py
        export FLASK_ENV=production
        if [ ! -d "$APP_DIR/migrations" ]; then
            flask db init
            echo "Миграционный репозиторий создан."
        fi
        if ! flask db migrate -m "Auto migration"; then
            echo "Ошибка при создании новых миграций. Удаление старых миграций и создание заново..."
            flask db stamp head
            flask db migrate
            flask db upgrade
        else
            echo "Миграция базы данных выполнена успешно."
            break
        fi
        ((ATTEMPT++))
    done
}

# Функция для деактивации виртуального окружения
deactivate_virtualenv() {
    echo "Деактивация виртуального окружения..."
    deactivate
}

# Функция для перезапуска приложения
restart_application() {
    echo "Перезапуск приложения..."
    pkill gunicorn || true
    gunicorn --bind 0.0.0.0:8000 app:app --chdir "$APP_DIR" --daemon --log-file="$LOG_DIR/gunicorn.log" --access-logfile="$LOG_DIR/access.log"
    echo "Приложение перезапущено."
}

# Последовательное выполнение всех функций с логированием
create_database_backup || error_exit
cleanup || error_exit
setup || error_exit
restore_database || true  # Продолжить выполнение даже если восстановление не удалось
update_repository || error_exit
activate_virtualenv || error_exit
install_python_packages || error_exit
run_database_migration || error_exit
deactivate_virtualenv || error_exit
restart_application || error_exit

# Вывод сообщения об успешном завершении обновления
echo "Обновление успешно завершено: $(date)"
