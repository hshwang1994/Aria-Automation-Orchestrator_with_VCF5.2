#!/bin/bash

# 사용법 함수
usage() {
    echo "Usage: $0 <mount_point> <required_size_GB>"
    echo "Example: $0 /data 50"
    exit 1
}

# 파라미터 체크
if [ $# -ne 2 ]; then
    usage
fi

MOUNT_POINT=$1
REQUIRED_SIZE_GB=$2
VG_NAME="vg_data"
LV_NAME="lv$(basename $MOUNT_POINT)"

# LVM 관련 유틸리티 체크
for cmd in pvcreate vgcreate lvcreate vgs lvs pvs lvresize resize2fs; do
    if ! command -v $cmd &> /dev/null; then
        logger -p user.error "Error: $cmd command not found. Please install LVM2"
        echo "Error: $cmd command not found. Please install LVM2"
        exit 1
    fi
done

# 부팅 디바이스 확인
BOOT_DEVICE=$(df / | grep -v Filesystem | awk '{print $1}' | sed 's/[0-9]*$//')

# 사용 가능한 디바이스 찾기
find_available_device() {
    local available_device=""
    for device in $(lsblk -dpno NAME | grep "^/dev/"); do
        # 부팅 디바이스 제외
        if [ "$device" = "$BOOT_DEVICE" ]; then
            continue
        fi
        
        # 마운트된 디바이스 제외
        if grep -q "^$device" /proc/mounts; then
            continue
        fi
        
        # 파티션이 있는 디바이스 제외
        if lsblk -no TYPE "$device" | grep -q "part\|lvm"; then
            continue
        fi
        
        # LVM PV로 사용 중인 디바이스 제외
        if pvs "$device" &>/dev/null; then
            continue
        fi
        
        # 디바이스가 실제로 존재하고 블록 디바이스인지 확인
        if [ -b "$device" ]; then
            available_device="$device"
            break
        fi
    done
    
    if [ -n "$available_device" ]; then
        echo "$available_device"
    fi
}

# 볼륨 그룹 존재 여부 확인 및 처리
handle_volume_group() {
    if ! vgs $VG_NAME &> /dev/null; then
        # 새 디바이스 찾기
        local new_device=$(find_available_device)
        if [ -z "$new_device" ]; then
            logger -p user.error "Error: No available devices found"
            echo "Error: No available devices found"
            exit 1
        fi
        
        echo "Creating new volume group with device: $new_device"
        
        # 물리 볼륨 생성
        if ! pvcreate "$new_device"; then
            logger -p user.error "Error: Failed to create physical volume on $new_device"
            echo "Error: Failed to create physical volume on $new_device"
            exit 1
        fi
        
        # 볼륨 그룹 생성
        if ! vgcreate $VG_NAME "$new_device"; then
            logger -p user.error "Error: Failed to create volume group $VG_NAME"
            echo "Error: Failed to create volume group $VG_NAME"
            exit 1
        fi
    fi
    
    # 볼륨 그룹의 여유 공간 확인
    local free_space=$(vgs --noheadings --units g -o vg_free $VG_NAME | tr -d ' ' | cut -d'.' -f1)
    
    # 필요한 경우 볼륨 그룹 확장
    local needed_space=$REQUIRED_SIZE_GB
    
    # 만약 기존 LV가 있다면, 필요한 추가 공간만 계산
    if lvs --noheadings $VG_NAME/$LV_NAME &>/dev/null; then
        local current_size=$(lvs --noheadings --units g -o lv_size $VG_NAME/$LV_NAME | tr -d ' ' | cut -d'.' -f1)
        if [ $REQUIRED_SIZE_GB -gt $current_size ]; then
            needed_space=$(( $REQUIRED_SIZE_GB - $current_size ))
        else
            # 요청 크기가 현재 크기보다 작거나 같으면 추가 공간 필요 없음
            needed_space=0
        fi
    fi
    
    # 볼륨 그룹 확장이 필요한 경우
    while [ $needed_space -gt $free_space ]; do
        echo "Need more space. Current free space: ${free_space}GB, Required additional: ${needed_space}GB"
        extend_volume_group
        free_space=$(vgs --noheadings --units g -o vg_free $VG_NAME | tr -d ' ' | cut -d'.' -f1)
    done
}

# 볼륨 그룹 용량 확장
extend_volume_group() {
    local new_device=$(find_available_device)
    if [ -z "$new_device" ]; then
        logger -p user.error "Error: No available devices found for extension"
        echo "Error: No available devices found for extension"
        exit 1
    fi
    
    echo "Extending volume group with device: $new_device"
    
    # 새 물리 볼륨 생성 및 볼륨 그룹 확장
    if ! pvcreate "$new_device" || \
       ! vgextend $VG_NAME "$new_device"; then
        logger -p user.error "Error: Failed to extend volume group with $new_device"
        echo "Error: Failed to extend volume group with $new_device"
        exit 1
    fi
    
    echo "Successfully extended volume group with device: $new_device"
}

# 마운트 포인트 생성
create_mount_point() {
    if [ ! -d "$MOUNT_POINT" ]; then
        if ! mkdir -p "$MOUNT_POINT"; then
            logger -p user.error "Error: Failed to create mount point $MOUNT_POINT"
            echo "Error: Failed to create mount point $MOUNT_POINT"
            exit 1
        fi
    fi
}

# 논리 볼륨 확장 (축소는 지원하지 않음)
extend_logical_volume() {
    # 현재 LV 크기 확인
    local current_size=$(lvs --noheadings --units g -o lv_size $VG_NAME/$LV_NAME | tr -d ' ' | cut -d'.' -f1)
    
    if [ $current_size -eq $REQUIRED_SIZE_GB ]; then
        echo "Logical volume is already ${REQUIRED_SIZE_GB}GB in size. No resize needed."
        return 0
    elif [ $current_size -lt $REQUIRED_SIZE_GB ]; then
        # 확장
        echo "Extending logical volume from ${current_size}GB to ${REQUIRED_SIZE_GB}GB"
        
        # LV 크기 확장
        if ! lvresize -L ${REQUIRED_SIZE_GB}G $VG_NAME/$LV_NAME; then
            logger -p user.error "Error: Failed to extend logical volume $LV_NAME"
            echo "Error: Failed to extend logical volume $LV_NAME"
            return 1
        fi
        
        # 파일시스템 확장
        if ! resize2fs /dev/$VG_NAME/$LV_NAME; then
            logger -p user.error "Error: Failed to extend filesystem on /dev/$VG_NAME/$LV_NAME"
            echo "Error: Failed to extend filesystem on /dev/$VG_NAME/$LV_NAME"
            return 1
        fi
        
        echo "Successfully extended logical volume to ${REQUIRED_SIZE_GB}GB"
    else
        # 현재 크기가 요청된 크기보다 큰 경우 (축소 필요)
        echo "Current volume size (${current_size}GB) is larger than requested size (${REQUIRED_SIZE_GB}GB)"
        echo "Volume shrinking is not supported in this script for data safety."
        echo "No changes were made to the volume."
        return 0
    fi
    
    return 0
}

# 마운트 포인트가 이미 사용 중인지 확인
check_existing_mount() {
    # fstab에서 확인
    if grep -q " $MOUNT_POINT " /etc/fstab; then
        return 0
    fi
    
    # 현재 마운트된 파일시스템에서 확인
    if grep -q " $MOUNT_POINT " /proc/mounts; then
        return 0
    fi
    
    return 1
}

# 메인 로직
create_mount_point
handle_volume_group

# 이미 마운트 포인트가 사용 중인지 확인
if check_existing_mount; then
    echo "Mount point $MOUNT_POINT is already in use"
    
    # 현재 LV 확인
    if lvs $VG_NAME/$LV_NAME &>/dev/null; then
        echo "Found existing logical volume $VG_NAME/$LV_NAME"
        # 논리 볼륨 크기 확장 (필요한 경우)
        extend_logical_volume
        if [ $? -eq 0 ]; then
            echo "Volume operation completed successfully"
        else
            echo "Volume extension failed"
            exit 1
        fi
    else
        logger -p user.error "Error: Mount point $MOUNT_POINT exists but could not find logical volume $VG_NAME/$LV_NAME"
        echo "Error: Mount point $MOUNT_POINT exists but could not find logical volume $VG_NAME/$LV_NAME"
        exit 1
    fi
else
    # 새 논리 볼륨 생성
    if ! echo "y" | lvcreate -L ${REQUIRED_SIZE_GB}G -n $LV_NAME $VG_NAME; then
        logger -p user.error "Error: Failed to create logical volume $LV_NAME"
        echo "Error: Failed to create logical volume $LV_NAME"
        exit 1
    fi

    # 파일시스템 생성
    if ! mkfs.ext4 "/dev/$VG_NAME/$LV_NAME"; then
        logger -p user.error "Error: Failed to create filesystem on /dev/$VG_NAME/$LV_NAME"
        echo "Error: Failed to create filesystem on /dev/$VG_NAME/$LV_NAME"
        exit 1
    fi

    # fstab에 마운트 정보 추가 및 중복 체크
    if ! grep -q "^/dev/$VG_NAME/$LV_NAME $MOUNT_POINT" /etc/fstab; then
        echo "/dev/$VG_NAME/$LV_NAME $MOUNT_POINT ext4 defaults 0 0" >> /etc/fstab
        if [ $? -ne 0 ]; then
            logger -p user.error "Error: Failed to update /etc/fstab"
            echo "Error: Failed to update /etc/fstab"
            exit 1
        fi
    fi

    # 마운트 실행
    if ! mount "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"; then
        logger -p user.error "Error: Failed to mount /dev/$VG_NAME/$LV_NAME to $MOUNT_POINT"
        echo "Error: Failed to mount /dev/$VG_NAME/$LV_NAME to $MOUNT_POINT"
        exit 1
    fi

    # 성공 로그 기록
    logger -p user.info "Successfully created and mounted ${REQUIRED_SIZE_GB}GB volume at $MOUNT_POINT"
    echo "Successfully created and mounted ${REQUIRED_SIZE_GB}GB volume at $MOUNT_POINT"
fi

# 현재 볼륨 그룹 상태 출력
echo "Current Volume Group Status:"
vgs $VG_NAME
echo "Current Logical Volumes:"
lvs $VG_NAME