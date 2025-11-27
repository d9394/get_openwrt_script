#!/bin/bash

# --- 辅助函数 ---

# 交互式选择备份文件
select_backup() {
    # 查找所有符合 openwrt-YYYYMMDD-HHMMSS.tar.gz 格式的备份文件
    mapfile -t backups < <(ls -1 openwrt-????????-??????.tar.gz 2>/dev/null | sort -r)

    if [ ${#backups[@]} -eq 0 ]; then
        return 1 # 没有找到备份文件
    fi

    echo "--- 找到已存在的 OpenWrt 备份文件 ---"
    echo "请选择要恢复的备份，或选择重新下载："

    # 添加一个 "重新下载" 的选项
    backups+=("重新下载/Re-download")

    # 交互式选择
    select choice in "${backups[@]}"; do
        if [ -n "$choice" ]; then
            RECOVERY_CHOICE="$choice"
            break
        else
            echo "无效选择，请输入对应编号。"
        fi
    done

    # 检查是否选择了 "重新下载"
    if [[ "$RECOVERY_CHOICE" == "重新下载/Re-download" ]]; then
        return 0 # 选择重新下载
    else
        echo "你选择了恢复备份: $RECOVERY_CHOICE"
        return 2 # 选择恢复备份
    fi
}

# 恢复指定的备份文件
restore_backup() {
    local tar_file="$1"
    echo "正在恢复备份 $tar_file ..."

    # 检查 openwrt 目录是否存在并删除
    if [ -d "openwrt" ]; then
        echo "清理旧的 openwrt 目录..."
        rm -rf openwrt
    fi

    # 解压备份文件
    tar -xzf "$tar_file"
    if [ $? -ne 0 ]; then
        echo "💥 恢复备份失败，请检查文件或权限。"
        exit 1
    fi
    echo "✅ 备份已成功恢复。"
}

# 克隆 OpenWrt 仓库
clone_openwrt() {
    # 设置 Git 不验证 SSL（仅内网或可信环境使用）
    git config --global http.sslVerify false

    # 删除旧的 openwrt 目录（可选）
    echo "清理旧的 openwrt 目录..."
    rm -rf openwrt

    # 浅层克隆 OpenWrt 仓库（只克隆主干，加快速度）
    echo "正在克隆 OpenWrt 主仓库..."
    git clone https://github.com/openwrt/openwrt.git
    if [ $? -ne 0 ]; then
        echo "💥 克隆失败，请检查网络或仓库地址"
        exit 1
    fi

    # 打包当前克隆的仓库（时间戳命名）
    TAR_FILE="openwrt-$(date +"%Y%m%d-%H%M%S").tar.gz"
    echo "正在打包为 $TAR_FILE ..."
    tar -czf "$TAR_FILE" ./openwrt
    echo "已保存备份: $TAR_FILE"
}

# --- 主逻辑 ---

# 进入用户主目录
cd ~ || exit 1

RECOVERY_CHOICE=""
# 尝试查找和选择备份
select_backup
BACKUP_STATUS=$? # 0: 重新下载/未找到, 2: 恢复备份, 1: 未找到

# 处理选择结果
if [ $BACKUP_STATUS -eq 2 ]; then
    # 选择了恢复备份
    restore_backup "$RECOVERY_CHOICE"
elif [ $BACKUP_STATUS -eq 0 ] || [ $BACKUP_STATUS -eq 1 ]; then
    # 选择了重新下载 或 没有找到备份
    echo "--- 重新下载 OpenWrt 源码 ---"
    clone_openwrt
fi

# --- 进入版本选择和配置阶段 ---

# 进入 openwrt 目录
cd openwrt || exit 1

# 创建 dl 目录软链接
# OpenWrt 编译时会将下载的源码包放在此目录
ln -sf ~/dl ./dl

# 获取远程版本标签（v18.06.0, v21.02.3 等格式的稳定版本）
echo "正在获取可用的 OpenWrt 版本..."
# 过滤出类似 v18.06.x, v19.07.x, v21.02.x, v22.03.x, v23.05.x 的稳定标签
mapfile -t tags < <(git tag -l | grep -E '^v(1[89]\.06|19\.07|2[1-9]\.[0-9]{2})\.[0-9]+$' | sort -Vr)

# 获取远程分支（如 openwrt-18.06, openwrt-21.02）
mapfile -t branches < <(git branch -r | sed 's/^[[:space:]]*origin\///' | grep -E '^openwrt-[0-9]+\.[0-9]+$' | sort -Vr)

# 合并去重（优先用 tag，避免重复）
declare -A seen
choices=()

for tag in "${tags[@]}"; do
    if [[ -z ${seen[$tag]} ]]; then
        choices+=("$tag")
        seen[$tag]=1
    fi
done

for branch in "${branches[@]}"; do
    if [[ -z ${seen[$branch]} ]]; then
        choices+=("$branch")
        seen[$branch]=1
    fi
done

# 添加主分支选项
choices+=("master")

# 检查是否有可用选项
if [ ${#choices[@]} -eq 0 ]; then
    echo "💥 未找到任何可用版本，请检查网络或仓库。"
    exit 1
fi

# 交互式选择
echo "请选择要切换的 OpenWrt 版本："
select choice in "${choices[@]}"; do
    if [ -n "$choice" ]; then
        echo "你选择了: $choice"
        break
    else
        echo "无效选择，请输入对应编号。"
    fi
done

# 切换到用户选择的版本
echo "正在切换到 $choice ..."

if [[ "$choice" == v* ]]; then
    # 是标签，直接检出
    git checkout "$choice"
elif [[ "$choice" == "master" ]]; then
    git checkout master
else
    # 是分支，尝试检出远程分支
    # 注意：如果分支是从备份恢复的，可能需要在 git fetch 之后才能看到远程分支
    # 由于 openwrt 目录是从备份恢复的，这里确保切换到本地分支或远程分支
    git checkout "$choice" || git checkout -b "$choice" "origin/$choice"
fi

if [ $? -ne 0 ]; then
    echo "💥 切换版本失败，请检查日志。"
    exit 1
fi

# 更新 feeds
echo "更新 feeds..."
./scripts/feeds update -a
if [ $? -ne 0 ]; then
    echo "feeds 更新失败"
    exit 1
fi

echo "安装 feeds..."
./scripts/feeds install -a
if [ $? -ne 0 ]; then
    echo "feeds 安装失败"
    exit 1
fi

echo "✅ 构建环境准备完成，当前版本: $choice"
