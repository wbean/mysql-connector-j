# =============================================================================
# MySQL Connector/J - Makefile
# =============================================================================
# 用法:
#   make setup      - 一键初始化环境（下载依赖 + 生成配置文件）
#   make compile    - 编译源码
#   make build      - 编译 + 打包 JAR（默认）
#   make package    - 打包含源码的完整发行包
#   make clean      - 清理编译产物
#   make distclean  - 清理编译产物 + 依赖库 + 配置文件
#   make info       - 显示当前构建环境信息
# =============================================================================

# ------------ 依赖版本 ------------
JAVASSIST_VERSION        := 3.29.2-GA
PROTOBUF_VERSION         := 3.25.3
SLF4J_VERSION            := 1.7.36
C3P0_VERSION             := 0.9.5.5
MCHANGE_VERSION          := 0.2.20
OPENTELEMETRY_VERSION    := 1.38.0
OCI_SDK_VERSION          := 3.47.0

# ------------ 目录 ------------
LIB_DIR     := lib
BUILD_DIR   := build
DIST_DIR    := dist

# ------------ 自动检测 JDK 8 ------------
# 优先使用环境变量 JAVA8_HOME，否则自动查找
ifndef JAVA8_HOME
  # macOS: 用 java_home 工具自动找
  JAVA8_HOME := $(shell /usr/libexec/java_home -v 1.8 2>/dev/null)
  # Linux: 常见路径
  ifeq ($(JAVA8_HOME),)
    JAVA8_HOME := $(shell find /usr/lib/jvm /usr/java -maxdepth 2 -name "release" 2>/dev/null \
                  | xargs grep -l 'JAVA_VERSION="1.8' 2>/dev/null \
                  | head -1 | xargs dirname 2>/dev/null)
  endif
  ifeq ($(JAVA8_HOME),)
    JAVA8_HOME := /usr/lib/jvm/jdk1.8
  endif
endif

# ------------ Maven 中央仓库 ------------
MVN_REPO    := https://repo1.maven.org/maven2

# JAR 下载 URL 列表
JAR_JAVASSIST       := $(MVN_REPO)/org/javassist/javassist/$(JAVASSIST_VERSION)/javassist-$(JAVASSIST_VERSION).jar
JAR_PROTOBUF        := $(MVN_REPO)/com/google/protobuf/protobuf-java/$(PROTOBUF_VERSION)/protobuf-java-$(PROTOBUF_VERSION).jar
JAR_SLF4J           := $(MVN_REPO)/org/slf4j/slf4j-api/$(SLF4J_VERSION)/slf4j-api-$(SLF4J_VERSION).jar
JAR_C3P0            := $(MVN_REPO)/com/mchange/c3p0/$(C3P0_VERSION)/c3p0-$(C3P0_VERSION).jar
JAR_MCHANGE         := $(MVN_REPO)/com/mchange/mchange-commons-java/$(MCHANGE_VERSION)/mchange-commons-java-$(MCHANGE_VERSION).jar
JAR_OTEL_API        := $(MVN_REPO)/io/opentelemetry/opentelemetry-api/$(OPENTELEMETRY_VERSION)/opentelemetry-api-$(OPENTELEMETRY_VERSION).jar
JAR_OTEL_CTX        := $(MVN_REPO)/io/opentelemetry/opentelemetry-context/$(OPENTELEMETRY_VERSION)/opentelemetry-context-$(OPENTELEMETRY_VERSION).jar
JAR_OCI             := $(MVN_REPO)/com/oracle/oci/sdk/oci-java-sdk-common/$(OCI_SDK_VERSION)/oci-java-sdk-common-$(OCI_SDK_VERSION).jar

ALL_JARS := \
	$(LIB_DIR)/javassist-$(JAVASSIST_VERSION).jar \
	$(LIB_DIR)/protobuf-java-$(PROTOBUF_VERSION).jar \
	$(LIB_DIR)/slf4j-api-$(SLF4J_VERSION).jar \
	$(LIB_DIR)/c3p0-$(C3P0_VERSION).jar \
	$(LIB_DIR)/mchange-commons-java-$(MCHANGE_VERSION).jar \
	$(LIB_DIR)/opentelemetry-api-$(OPENTELEMETRY_VERSION).jar \
	$(LIB_DIR)/opentelemetry-context-$(OPENTELEMETRY_VERSION).jar \
	$(LIB_DIR)/oci-java-sdk-common-$(OCI_SDK_VERSION).jar

# =============================================================================
# 默认目标
# =============================================================================
.DEFAULT_GOAL := build

.PHONY: all build compile package package-no-sources clean distclean setup \
        deps config check-tools info help

# =============================================================================
# help - 显示帮助
# =============================================================================
help:
	@echo ""
	@echo "MySQL Connector/J 构建工具"
	@echo "=========================="
	@echo ""
	@echo "  make setup              一键初始化环境（下载依赖 + 生成 build.properties）"
	@echo "  make compile            仅编译源码"
	@echo "  make build              编译 + 打包 JAR（默认目标）"
	@echo "  make package            打包含源码的完整发行包"
	@echo "  make package-no-sources 打包不含源码的发行包"
	@echo "  make clean              清理编译产物（build/ dist/）"
	@echo "  make distclean          清理编译产物 + lib/ + build.properties"
	@echo "  make info               显示当前环境信息"
	@echo "  make help               显示此帮助"
	@echo ""
	@echo "自定义 JDK 8 路径（当自动检测失败时）:"
	@echo "  make setup JAVA8_HOME=/path/to/jdk8"
	@echo ""

# =============================================================================
# info - 显示环境信息
# =============================================================================
info:
	@echo ""
	@echo "====== 构建环境信息 ======"
	@echo "JDK 8 路径  : $(JAVA8_HOME)"
	@echo "依赖目录    : $(LIB_DIR)/"
	@echo "构建输出    : $(BUILD_DIR)/"
	@echo "Ant 版本    :"
	@ant -version 2>&1 | sed 's/^/              /'
	@echo "已下载 JAR  :"
	@ls $(LIB_DIR)/*.jar 2>/dev/null | sed 's|$(LIB_DIR)/||' | sed 's/^/  - /' || echo "  (无，请先运行 make setup)"
	@echo ""

# =============================================================================
# check-tools - 检查必要工具
# =============================================================================
check-tools:
	@command -v ant >/dev/null 2>&1 || { \
		echo "❌ 未找到 ant，请先安装:"; \
		echo "   macOS:  brew install ant"; \
		echo "   Linux:  sudo apt install ant  或  sudo yum install ant"; \
		exit 1; \
	}
	@command -v curl >/dev/null 2>&1 || { echo "❌ 未找到 curl，请先安装 curl"; exit 1; }
	@test -n "$(JAVA8_HOME)" && test -f "$(JAVA8_HOME)/bin/java" || { \
		echo "❌ 未找到 JDK 8，请手动指定路径:"; \
		echo "   make setup JAVA8_HOME=/path/to/jdk8"; \
		exit 1; \
	}
	@echo "✅ 工具检查通过"
	@echo "   Ant  : $$(ant -version 2>&1)"
	@echo "   JDK8 : $(JAVA8_HOME)"

# =============================================================================
# setup - 一键初始化环境
# =============================================================================
setup: check-tools deps config
	@echo ""
	@echo "🎉 环境初始化完成！现在可以运行:"
	@echo "   make compile   # 仅编译"
	@echo "   make build     # 编译 + 打包 JAR"
	@echo ""

# =============================================================================
# deps - 下载所有依赖 JAR
# =============================================================================
deps: $(ALL_JARS)
	@echo "✅ 所有依赖已就绪"

$(LIB_DIR):
	@mkdir -p $(LIB_DIR)

# 通用下载规则：每个 JAR 单独定义，make 会自动跳过已存在的文件
$(LIB_DIR)/javassist-$(JAVASSIST_VERSION).jar: | $(LIB_DIR)
	@echo "⬇️  下载 javassist-$(JAVASSIST_VERSION).jar ..."
	@curl -fsSL -o $@ $(JAR_JAVASSIST) || { echo "❌ 下载失败: $(JAR_JAVASSIST)"; rm -f $@; exit 1; }

$(LIB_DIR)/protobuf-java-$(PROTOBUF_VERSION).jar: | $(LIB_DIR)
	@echo "⬇️  下载 protobuf-java-$(PROTOBUF_VERSION).jar ..."
	@curl -fsSL -o $@ $(JAR_PROTOBUF) || { echo "❌ 下载失败: $(JAR_PROTOBUF)"; rm -f $@; exit 1; }

$(LIB_DIR)/slf4j-api-$(SLF4J_VERSION).jar: | $(LIB_DIR)
	@echo "⬇️  下载 slf4j-api-$(SLF4J_VERSION).jar ..."
	@curl -fsSL -o $@ $(JAR_SLF4J) || { echo "❌ 下载失败: $(JAR_SLF4J)"; rm -f $@; exit 1; }

$(LIB_DIR)/c3p0-$(C3P0_VERSION).jar: | $(LIB_DIR)
	@echo "⬇️  下载 c3p0-$(C3P0_VERSION).jar ..."
	@curl -fsSL -o $@ $(JAR_C3P0) || { echo "❌ 下载失败: $(JAR_C3P0)"; rm -f $@; exit 1; }

$(LIB_DIR)/mchange-commons-java-$(MCHANGE_VERSION).jar: | $(LIB_DIR)
	@echo "⬇️  下载 mchange-commons-java-$(MCHANGE_VERSION).jar ..."
	@curl -fsSL -o $@ $(JAR_MCHANGE) || { echo "❌ 下载失败: $(JAR_MCHANGE)"; rm -f $@; exit 1; }

$(LIB_DIR)/opentelemetry-api-$(OPENTELEMETRY_VERSION).jar: | $(LIB_DIR)
	@echo "⬇️  下载 opentelemetry-api-$(OPENTELEMETRY_VERSION).jar ..."
	@curl -fsSL -o $@ $(JAR_OTEL_API) || { echo "❌ 下载失败: $(JAR_OTEL_API)"; rm -f $@; exit 1; }

$(LIB_DIR)/opentelemetry-context-$(OPENTELEMETRY_VERSION).jar: | $(LIB_DIR)
	@echo "⬇️  下载 opentelemetry-context-$(OPENTELEMETRY_VERSION).jar ..."
	@curl -fsSL -o $@ $(JAR_OTEL_CTX) || { echo "❌ 下载失败: $(JAR_OTEL_CTX)"; rm -f $@; exit 1; }

$(LIB_DIR)/oci-java-sdk-common-$(OCI_SDK_VERSION).jar: | $(LIB_DIR)
	@echo "⬇️  下载 oci-java-sdk-common-$(OCI_SDK_VERSION).jar ..."
	@curl -fsSL -o $@ $(JAR_OCI) || { echo "❌ 下载失败: $(JAR_OCI)"; rm -f $@; exit 1; }

# =============================================================================
# config - 生成 build.properties
# =============================================================================
config:
	@if [ -f build.properties ]; then \
		echo "ℹ️  build.properties 已存在，跳过生成（如需重新生成请先删除该文件）"; \
	else \
		echo "📝 生成 build.properties ..."; \
		printf '# MySQL Connector/J 本地构建配置（由 make setup 自动生成）\n' > build.properties; \
		printf '# 第三方依赖库路径\n' >> build.properties; \
		printf 'com.mysql.cj.extra.libs=lib\n' >> build.properties; \
		printf '\n# JDK 8 路径\n' >> build.properties; \
		printf 'com.mysql.cj.build.jdk=%s\n' "$(JAVA8_HOME)" >> build.properties; \
		printf '\n# 加速：不清理上次编译结果\n' >> build.properties; \
		printf 'com.mysql.cj.build.noCleanBetweenCompiles=yes\n' >> build.properties; \
		echo "✅ build.properties 已生成"; \
	fi

# =============================================================================
# 构建目标（委托给 Ant）
# =============================================================================
compile:
	@echo "🔨 编译源码..."
	ant compile

build:
	@echo "📦 编译 + 打包 JAR..."
	ant build
	@echo ""
	@echo "✅ 构建成功！输出文件:"
	@ls -lh $(BUILD_DIR)/mysql-connector-j-*/mysql-connector-j-*.jar 2>/dev/null | awk '{print "   " $$NF " (" $$5 ")"}'
	@echo ""

package:
	@echo "📦 打包完整发行包（含源码）..."
	ant package

package-no-sources:
	@echo "📦 打包发行包（不含源码）..."
	ant package-no-sources

# =============================================================================
# 清理
# =============================================================================
clean:
	@echo "🧹 清理编译产物..."
	ant clean
	@rm -rf $(DIST_DIR)
	@echo "✅ 清理完成"

distclean: clean
	@echo "🧹 清理依赖库和配置文件..."
	@rm -rf $(LIB_DIR)
	@rm -f build.properties
	@echo "✅ 完全清理完成（运行 make setup 重新初始化）"
