#!/usr/bin/env bash

mvn() {
    local pom="" dir="$PWD"

    # Walk up to find nearest pom.xml
    while [[ "$dir" != "/" ]]; do
        [[ -f "$dir/pom.xml" ]] && pom="$dir/pom.xml" && break
        dir="$(dirname "$dir")"
    done

    # Java version auto-switch
    if [[ -n "$pom" && -r "$pom" ]]; then
        local java_version=""

        # Try inline first, then inside <properties>
        java_version=$(grep -m1 -E '<(java\.version|maven\.compiler\.release|maven\.compiler\.target)>[[:space:]]*[0-9]+' "$pom" 2>/dev/null \
            | sed -E 's/.*<[^>]*>([0-9]+)<[^>]*>.*/\1/' | tr -d ' ')

        if [[ -z "$java_version" ]]; then
            java_version=$(sed -n '/<properties>/,/<\/properties>/p' "$pom" 2>/dev/null \
                | grep -m1 -E '(java\.version|maven\.compiler\.release|maven\.compiler\.target)' \
                | sed -E 's/.*<[^>]*>([0-9]+)<[^>]*>.*/\1/' | tr -d ' ')
        fi

        if [[ -n "$java_version" ]]; then
            case "$java_version" in
                8|11|17|21|23) ;;
                *) echo "mvn: unknown Java version '$java_version' in pom.xml — skipping switch" >&2
                   java_version="" ;;
            esac
        fi

        if [[ -n "$java_version" ]]; then
            if ! command -v update-java-alternatives >/dev/null 2>&1; then
                echo "mvn: update-java-alternatives not found — sudo apt install java-common" >&2
            else
                # Match both naming conventions Ubuntu uses:
                #   modern: java-11-openjdk-amd64
                #   legacy: java-1.11.0-openjdk-amd64  (seen on some Ubuntu versions)
                local jvm_list target_line target target_path current_jvm
                jvm_list=$(update-java-alternatives -l 2>/dev/null)
                target_line=$(echo "$jvm_list" \
                    | grep -E "(java-${java_version}-openjdk|java-1\.${java_version}\.0-openjdk)" \
                    | head -1)

                if [[ -z "$target_line" ]]; then
                    echo "mvn: Java $java_version not installed — sudo apt install openjdk-${java_version}-jdk" >&2
                else
                    target=$(awk '{print $1}' <<< "$target_line")
                    target_path=$(awk '{print $3}' <<< "$target_line")
                    current_jvm=$(dirname "$(dirname "$(update-alternatives --query java 2>/dev/null \
                        | awk '/^Value:/{print $2}')")" 2>/dev/null || true)

                    if [[ "$current_jvm" != "$target_path" ]]; then
                        echo "Switching to Java $java_version ($target)"
                        sudo update-java-alternatives -s "$target" >/dev/null 2>&1 || \
                            echo "mvn: Java switch failed (sudo required)" >&2
                    fi
                fi
            fi
        fi
    fi

    # Maven wrapper: generate if missing OR if wrapper files are incomplete
    if [[ -f "./pom.xml" ]] && [[ ! -f "./mvnw" || ! -f "./.mvn/wrapper/maven-wrapper.properties" ]]; then
        [[ -f "./mvnw" ]] \
            && echo "mvn: mvnw exists but wrapper files are missing — regenerating..." >&2 \
            || echo "mvn: no mvnw found — generating Maven wrapper..." >&2
        local sys_mvn
        sys_mvn=$(find "$HOME/.m2/wrapper/dists" -name "mvn" -path "*/bin/mvn" -type f 2>/dev/null \
            | sort -V | tail -1)
        if [[ -z "$sys_mvn" ]]; then
            echo "mvn: cannot generate mvnw — no cached Maven in ~/.m2/wrapper/dists" >&2
            echo "mvn: run: mvn -N wrapper:wrapper  (using system mvn first)" >&2
            return 1
        fi
        local latest_maven
        latest_maven=$(curl -s --max-time 5 \
            "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml" 2>/dev/null \
            | grep '<version>' \
            | sed 's/.*<version>\(.*\)<\/version>.*/\1/' \
            | grep -vE 'alpha|beta|rc|RC|milestone' \
            | sort -V | tail -1)
        [[ -z "$latest_maven" ]] && latest_maven="3.9.12"
        echo "mvn: using Maven $latest_maven" >&2
        if ! "$sys_mvn" wrapper:wrapper -Dmaven="$latest_maven" >/dev/null 2>&1; then
            echo "mvn: failed to generate wrapper" >&2
            return 1
        fi
        echo "mvn: mvnw generated" >&2
    fi

    # Run
    if [[ -f "./mvnw" ]]; then
        [[ ! -x "./mvnw" ]] && chmod +x "./mvnw"
        ./mvnw "$@"
    elif [[ -z "$pom" ]]; then
        echo "mvn: no pom.xml found in $PWD or any parent directory" >&2
        return 1
    else
        echo "mvn: no mvnw in $PWD — run from project root" >&2
        return 1
    fi
}

_mvn_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    local goals="clean compile test package verify install deploy site \
        dependency:tree dependency:resolve dependency:sources dependency:copy dependency:analyze \
        archetype:generate"
    local plugins="spring-boot:run spring-boot:build-info \
        docker:build docker:push \
        versions:display-dependency-updates versions:display-property-updates versions:set"
    local options="-D -P -o -X -q -e -U -N -T -f -rf -pl -am -amd -B -C \
        -Dmaven.test.skip=true -DskipTests -DskipITs -Dmaven.javadoc.skip=true"

    if [[ "$prev" == "-f" || "$prev" == "--file" ]]; then
        COMPREPLY=($(compgen -f -X '!*.xml' -- "$cur"))
        return 0
    fi

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "$options" -- "$cur"))
        return 0
    fi

    if [[ "$cur" == *:* ]]; then
        case "${cur%%:*}" in
            spring-boot) goals+=" spring-boot:stop" ;;
            docker)      goals+=" docker:start docker:stop" ;;
            versions)    goals+=" versions:use-latest-versions" ;;
            exec)        goals+=" exec:java exec:exec" ;;
            surefire)    goals+=" surefire:test" ;;
            failsafe)    goals+=" failsafe:integration-test failsafe:verify" ;;
        esac
    fi

    COMPREPLY=($(compgen -W "$goals $plugins" -- "$cur"))
}

complete -F _mvn_completions mvn
