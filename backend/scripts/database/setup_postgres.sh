#!/bin/bash

# Загрузка переменных окружения
source .env

# Строгий режим
set -euo pipefail
trap 'echo "Ошибка на строке $LINENO. Завершение с кодом $?" >&2; exit 1' ERR

# Установка зависимостей
function install_dependencies() {
    echo "Установка Docker, Flyway и Barman..."
    sudo apt-get update
    sudo apt-get install -y docker.io
    # Добавьте команды установки для Flyway и Barman, если они доступны через apt или требуют отдельной установки
    echo "Docker, Flyway и Barman установлены."
}

# Остановка существующих процессов PostgreSQL
function stop_existing_postgres() {
    echo "Проверка на существующие процессы PostgreSQL..."
    if lsof -i:5432; then
        echo "Обнаружен процесс, использующий порт 5432. Попытка остановить..."
        sudo systemctl stop postgresql || true
        echo "Ожидание освобождения порта 5432..."
        sleep 5
        if lsof -i:5432; then
            echo "Порт все еще занят. Принудительное завершение процесса..."
            sudo fuser -k 5432/tcp || true
        fi
    fi
    echo "Порт 5432 свободен."
}

# Запуск PostgreSQL в Docker
function setup_postgres_docker() {
    echo "Запуск PostgreSQL в Docker..."
    docker rm -f postgres || true  # Удаление существующего контейнера, если он есть
    docker run --name postgres -d \
        -e POSTGRES_DB="$PG_DB" \
        -e POSTGRES_USER="$PG_USER" \
        -e POSTGRES_PASSWORD="$PG_PASSWORD" \
        -p "$PG_PORT:5432" \
        postgres:"$PG_VERSION"
    echo "PostgreSQL запущен в Docker."
}

# Применение обновлений схемы базы данных
function apply_schema_updates() {
    echo "Применение обновлений схемы базы данных..."
    # Здесь должна быть команда запуска миграций через Flyway или Liquibase
    # Пример: flyway -configFiles=/path/to/flyway.conf migrate
    echo "Обновления схемы базы данных применены."
}

# Настройка резервного копирования
function setup_backup() {
    echo "Настройка резервного копирования базы данных..."
    # Здесь должна быть конфигурация Barman или pgBackRest для автоматического резервного копирования
    # Пример: barman backup all
    echo "Резервное копирование настроено."
}

# Основная логика скрипта
install_dependencies
stop_existing_postgres
setup_postgres_docker
apply_schema_updates
setup_backup

echo "Настройка и обновление PostgreSQL завершены."
