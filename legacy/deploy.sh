#!/bin/bash

# PostgreSQL-Centric VoIP Stack Deployment Script
# Usage: ./deploy.sh [test|full|backup]

set -e

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m' # No Color

log_info() {
    echo -e "${COLOR_GREEN}✓ $1${COLOR_NC}"
}

log_error() {
    echo -e "${COLOR_RED}✗ $1${COLOR_NC}"
}

log_warn() {
    echo -e "${COLOR_YELLOW}⚠ $1${COLOR_NC}"
}

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    log_error "Docker is not running. Please start Docker first."
    exit 1
fi

# Parse command
COMMAND=${1:-test}

case $COMMAND in
    test)
        log_info "Starting TEST deployment (non-destructive)..."
        log_info "Using docker-compose.pgsql.yml"

        # Start PostgreSQL
        log_info "Starting PostgreSQL..."
        docker-compose -f docker-compose.pgsql.yml up -d postgres

        # Wait for PostgreSQL
        log_info "Waiting for PostgreSQL to be ready..."
        sleep 5

        # Check if schema was created
        docker-compose -f docker-compose.pgsql.yml exec -T postgres psql -U kamailio -d kamailio -c "SELECT COUNT(*) FROM tenants;" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_info "Database schema created successfully"
        else
            log_error "Database schema creation failed"
            exit 1
        fi

        # Start XML API
        log_info "Starting XML API..."
        docker-compose -f docker-compose.pgsql.yml up -d xmlapi

        # Wait for XML API
        sleep 3

        # Test XML API
        log_info "Testing XML API..."
        if curl -f http://localhost:8080/health > /dev/null 2>&1; then
            log_info "XML API is healthy"
        else
            log_warn "XML API health check failed (might need more time)"
        fi

        # Start all services
        log_info "Starting all services..."
        docker-compose -f docker-compose.pgsql.yml up -d

        log_info ""
        log_info "========================================="
        log_info "TEST DEPLOYMENT COMPLETE"
        log_info "========================================="
        log_info ""
        log_info "Services:"
        log_info "  - PostgreSQL: postgres:5432"
        log_info "  - XML API: http://localhost:8080"
        log_info "  - Kamailio: udp://localhost:5060"
        log_info "  - FreeSWITCH: udp://localhost:5061"
        log_info "  - pgAdmin: http://localhost:8081"
        log_info ""
        log_info "Test Users:"
        log_info "  - alice@tenant1.voip.local (password: alice123)"
        log_info "  - bob@tenant1.voip.local (password: bob123)"
        log_info "  - charlie@tenant2.voip.local (password: charlie123)"
        log_info ""
        log_info "Check logs: docker-compose -f docker-compose.pgsql.yml logs -f"
        log_info "Stop test: docker-compose -f docker-compose.pgsql.yml down"
        ;;

    full)
        log_warn "FULL DEPLOYMENT - This will replace your current system!"
        log_warn "Make sure you have a backup before proceeding."
        read -p "Continue? (yes/no): " confirm

        if [ "$confirm" != "yes" ]; then
            log_info "Deployment cancelled"
            exit 0
        fi

        log_info "Stopping current system..."
        docker-compose down

        log_warn "Removing PostgreSQL volume (data will be lost)..."
        docker volume rm voip_stack_pg_data 2>/dev/null || true

        log_info "Backing up old docker-compose.yml..."
        if [ -f docker-compose.yml ]; then
            mv docker-compose.yml docker-compose.old.yml
            log_info "Old compose saved as docker-compose.old.yml"
        fi

        log_info "Activating new docker-compose.yml..."
        cp docker-compose.pgsql.yml docker-compose.yml

        log_info "Updating FreeSWITCH modules configuration..."
        cp freeswitch/conf/autoload_configs/modules.conf.pgsql.xml \
           freeswitch/conf/autoload_configs/modules.conf.xml

        log_info "Starting new system..."
        docker-compose up -d

        log_info ""
        log_info "========================================="
        log_info "FULL DEPLOYMENT COMPLETE"
        log_info "========================================="
        log_info ""
        log_info "New system is now active!"
        log_info "Check logs: docker-compose logs -f"
        ;;

    backup)
        log_info "Creating backup..."

        BACKUP_FILE="backup_$(date +%Y%m%d_%H%M%S).sql"

        if docker-compose ps | grep -q postgres; then
            log_info "Backing up PostgreSQL database..."
            docker-compose exec -T postgres pg_dump -U kamailio kamailio > "$BACKUP_FILE"
            log_info "Backup saved to: $BACKUP_FILE"
        else
            log_error "PostgreSQL is not running. Cannot create backup."
            exit 1
        fi
        ;;

    *)
        echo "Usage: $0 [test|full|backup]"
        echo ""
        echo "Commands:"
        echo "  test   - Start test deployment (safe, non-destructive)"
        echo "  full   - Full deployment (replaces current system)"
        echo "  backup - Backup current database"
        exit 1
        ;;
esac
