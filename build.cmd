@echo off
@rem ============================================================================
@rem  REPS 命令行构建脚本
@rem
@rem  这台机器上直接跑 hvigorw 会踩 4 个坑,本脚本已全部绕开:
@rem   1. hvigor 启动时要 spawn powershell 检查 daemon 进程 -> 必须加 --no-daemon
@rem   2. 用户级 npm registry 指向失效的二进制源 -> 覆盖为 registry.npmmirror.com
@rem   3. 打包阶段需要 java,但不在 PATH 里 -> 补上 DevEco 自带 JBR
@rem   4. 找不到 SDK -> 显式设置 DEVECO_SDK_HOME
@rem
@rem  用法:  build.cmd [任务名]     默认任务 assembleHap
@rem         build.cmd clean
@rem
@rem  注意:退出码 1 但 stdout 里有 BUILD SUCCESSFUL 属于正常
@rem       (PowerShell 把 stderr 上的警告当成失败)。
@rem ============================================================================

setlocal

set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "NODE_HOME=%DEVECO%\tools\node"
set "JBR=%DEVECO%\jbr\bin"
set "DEVECO_SDK_HOME=%DEVECO%\sdk"
set "npm_config_registry=https://registry.npmmirror.com"
set "PATH=%JBR%;%NODE_HOME%;%PATH%"

set "TASK=%~1"
if "%TASK%"=="" set "TASK=assembleHap"

call "%DEVECO%\tools\hvigor\bin\hvigorw.bat" --no-daemon %TASK%
set "RC=%ERRORLEVEL%"

endlocal & exit /b %RC%
