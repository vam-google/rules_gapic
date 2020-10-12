# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("//rules_gapic:gapic_pkg.bzl", "construct_package_dir_paths", "put_dep_in_a_bucket", "pkg_tar")
load("@com_google_api_gax_java_properties//:dependencies.properties.bzl", "PROPERTIES")

def _wrapPropertyNamesInBraces(properties):
    wrappedProperties = {}
    for k, v in properties.items():
        wrappedProperties["{{%s}}" % k] = v
    return wrappedProperties

_PROPERTIES = _wrapPropertyNamesInBraces(PROPERTIES)

def _java_gapic_build_configs_pkg_impl(ctx):
    expanded_templates = []
    paths = construct_package_dir_paths(ctx.attr.package_dir, ctx.outputs.pkg, ctx.label.name)

    substitutions = dict(ctx.attr.static_substitutions)
    substitutions["{{extra_deps}}"] = _construct_extra_deps({
        "compile": ctx.attr.deps,
        "testCompile": ctx.attr.test_deps,
    }, substitutions)

    for template in ctx.attr.templates.items():
        expanded_template = ctx.actions.declare_file(
            "%s/%s" % (paths.package_dir_sibling_basename, template[1]),
            sibling = paths.package_dir_sibling_parent,
        )
        expanded_templates.append(expanded_template)
        ctx.actions.expand_template(
            template = template[0].files.to_list()[0],
            substitutions = substitutions,
            output = expanded_template,
        )

    # Note the script is more complicated than it intuitively should be because of the limitations
    # inherent to bazel execution environment: no absolute paths allowed, the generated artifacts
    # must ensure uniqueness within a build. The template output directory manipulations are
    # to modify default 555 file permissions on any generated by bazel file (exectuable read-only,
    # which is not at all what we need for build files). There is no bazel built-in way to change
    # the generated files permissions, also the actual files accessible by the script are symlinks
    # and `chmod`, when applied to a directory, does not change the attributes of symlink targets
    # inside the directory. Chaning the symlink target's permissions is also not an option, because
    # they are on a read-only file system.
    script = """
    mkdir -p {package_dir_path}
    for templ in {templates}; do
        cp $templ {package_dir_path}/
    done
    chmod 644 {package_dir_path}/*
    cd {package_dir_path}/{tar_cd_suffix}
    tar -zchpf {tar_prefix}/{package_dir}.tar.gz {tar_prefix}/*
    cd -
    mv {package_dir_path}/{package_dir}.tar.gz {pkg}
    """.format(
        templates = " ".join(["'%s'" % f.path for f in expanded_templates]),
        package_dir_path = paths.package_dir_path,
        package_dir = paths.package_dir,
        pkg = ctx.outputs.pkg.path,
        tar_cd_suffix = paths.tar_cd_suffix,
        tar_prefix = paths.tar_prefix,
    )

    ctx.actions.run_shell(
        inputs = expanded_templates,
        command = script,
        outputs = [ctx.outputs.pkg],
    )

java_gapic_build_configs_pkg = rule(
    attrs = {
        "deps": attr.label_list(mandatory = True),
        "test_deps": attr.label_list(mandatory = False, allow_empty = True),
        "package_dir": attr.string(mandatory = False),
        "templates": attr.label_keyed_string_dict(mandatory = False, allow_files = True),
        "static_substitutions": attr.string_dict(mandatory = False, allow_empty = True, default = {}),
    },
    outputs = {"pkg": "%{name}.tar.gz"},
    implementation = _java_gapic_build_configs_pkg_impl,
)

def _java_gapic_srcs_pkg_impl(ctx):
    srcs = []
    proto_srcs = []
    for src_dep in ctx.attr.deps:
        if _is_source_dependency(src_dep):
            srcs.extend(src_dep[JavaInfo].source_jars)
        if _is_proto_dependency(src_dep):
            proto_srcs.extend(src_dep[ProtoInfo].check_deps_sources.to_list())

    test_srcs = []
    for test_src_dep in ctx.attr.test_deps:
        if _is_source_dependency(test_src_dep):
            test_srcs.extend(test_src_dep[JavaInfo].source_jars)

    paths = construct_package_dir_paths(ctx.attr.package_dir, ctx.outputs.pkg, ctx.label.name)

    # Note the script is more complicated than it intuitively should be because of limitations
    # inherent to bazel execution environment: no absolute paths allowed, the generated artifacts
    # must ensure uniqueness within a build.
    script = """
    for src in {srcs}; do
        mkdir -p {package_dir_path}/src/main/java
        unzip -q -o $src -d {package_dir_path}/src/main/java
        rm -r -f {package_dir_path}/src/main/java/META-INF
    done
    for proto_src in {proto_srcs}; do
        mkdir -p {package_dir_path}/src/main/proto
        cp -f --parents $proto_src {package_dir_path}/src/main/proto
    done
    for test_src in {test_srcs}; do
        mkdir -p {package_dir_path}/src/test/java
        unzip -q -o $test_src -d {package_dir_path}/src/test/java
        rm -r -f {package_dir_path}/src/test/java/META-INF
    done
    cd {package_dir_path}/{tar_cd_suffix}
    tar -zchpf {tar_prefix}/{package_dir}.tar.gz {tar_prefix}/*
    cd -
    mv {package_dir_path}/{package_dir}.tar.gz {pkg}
    """.format(
        srcs = " ".join(["'%s'" % f.path for f in srcs]),
        proto_srcs = " ".join(["'%s'" % f.path for f in proto_srcs]),
        test_srcs = " ".join(["'%s'" % f.path for f in test_srcs]),
        package_dir_path = paths.package_dir_path,
        package_dir = paths.package_dir,
        pkg = ctx.outputs.pkg.path,
        tar_cd_suffix = paths.tar_cd_suffix,
        tar_prefix = paths.tar_prefix,
    )

    ctx.actions.run_shell(
        inputs = srcs + proto_srcs + test_srcs,
        command = script,
        outputs = [ctx.outputs.pkg],
    )

java_gapic_srcs_pkg = rule(
    attrs = {
        "deps": attr.label_list(mandatory = True),
        "test_deps": attr.label_list(mandatory = False, allow_empty = True),
        "package_dir": attr.string(mandatory = True),
    },
    outputs = {"pkg": "%{name}.tar.gz"},
    implementation = _java_gapic_srcs_pkg_impl,
)

def java_gapic_assembly_gradle_pkg(
        name,
        deps,
        assembly_name = None,
        transport = None,
        **kwargs):
    package_dir = name
    if assembly_name:
        package_dir = "google-cloud-%s-%s" % (assembly_name, name)
    proto_target = "proto-%s" % package_dir
    proto_target_dep = []
    grpc_target = "grpc-%s" % package_dir
    grpc_target_dep = []
    client_target = "gapic-%s" % package_dir
    client_target_dep = []

    client_deps = []
    client_test_deps = []
    grpc_deps = []
    proto_deps = []

    processed_deps = {} #there is no proper Set in Starlark
    for dep in deps:
        if dep.endswith("_java_gapic"):
            put_dep_in_a_bucket(dep, client_deps, processed_deps)
            put_dep_in_a_bucket("%s_test" % dep, client_test_deps, processed_deps)
            put_dep_in_a_bucket("%s_resource_name" % dep, proto_deps, processed_deps)
        elif dep.endswith("_java_grpc"):
            put_dep_in_a_bucket(dep, grpc_deps, processed_deps)
        else:
            put_dep_in_a_bucket(dep, proto_deps, processed_deps)

    if proto_deps:
        _java_gapic_gradle_pkg(
            name = proto_target,
            template_label = Label("//rules_gapic/java:resources/gradle/proto.gradle.tmpl"),
            deps = proto_deps,
            **kwargs
        )
        proto_target_dep = [":%s" % proto_target]

    if grpc_deps:
        _java_gapic_gradle_pkg(
            name = grpc_target,
            template_label = Label("//rules_gapic/java:resources/gradle/grpc.gradle.tmpl"),
            deps = proto_target_dep + grpc_deps,
            **kwargs
        )
        grpc_target_dep = ["%s" % grpc_target]

    if client_deps:
        if transport == "rest":
            template_label = Label("//rules_gapic/java:resources/gradle/client_disco.gradle.tmpl")
        else:
            template_label = Label("//rules_gapic/java:resources/gradle/client.gradle.tmpl")

        _java_gapic_gradle_pkg(
            name = client_target,
            template_label = template_label,
            deps = proto_target_dep + client_deps,
            test_deps = grpc_target_dep + client_test_deps,
            **kwargs
        )
        client_target_dep = ["%s" % client_target]

    _java_gapic_assembly_gradle_pkg(
        name = name,
        assembly_name = package_dir,
        deps = proto_target_dep + grpc_target_dep + client_target_dep,
    )

def java_discogapic_assembly_gradle_pkg(
        name,
        deps,
        assembly_name = None,
        **kwargs):
    package_dir = name
    if assembly_name:
        package_dir = "google-cloud-%s-%s" % (assembly_name, name)
    client_target = "gapic-%s" % package_dir
    client_target_dep = []

    client_deps = []
    client_test_deps = []

    processed_deps = {} #there is no proper Set in Starlark
    for dep in deps:
        if dep.endswith("_java_gapic"):
            put_dep_in_a_bucket(dep, client_deps, processed_deps)
            put_dep_in_a_bucket("%s_test" % dep, client_test_deps, processed_deps)

    if client_deps:
        _java_gapic_gradle_pkg(
            name = client_target,
            template_label = Label("//rules_gapic/java:resources/gradle/client_disco.gradle.tmpl"),
            deps = client_deps,
            test_deps = client_test_deps,
            **kwargs
        )
        client_target_dep = ["%s" % client_target]

    _java_gapic_assembly_gradle_pkg(
        name = name,
        assembly_name = package_dir,
        deps = client_target_dep,
    )

def _java_gapic_gradle_pkg(
        name,
        template_label,
        deps,
        test_deps = None,
        project_deps = None,
        test_project_deps = None,
        **kwargs):
    resource_target_name = "%s-resources" % name

    static_substitutions = dict(_PROPERTIES)
    static_substitutions["{{name}}"] = name

    java_gapic_build_configs_pkg(
        name = resource_target_name,
        deps = deps,
        test_deps = test_deps,
        package_dir = name,
        templates = {
            template_label: "build.gradle",
        },
        static_substitutions = static_substitutions,
    )

    srcs_pkg_target_name = "%s-srcs_pkg" % name
    java_gapic_srcs_pkg(
        name = srcs_pkg_target_name,
        deps = deps,
        test_deps = test_deps,
        package_dir = name,
        **kwargs
    )

    pkg_tar(
        name = name,
        extension = "tar.gz",
        deps = [
            resource_target_name,
            srcs_pkg_target_name,
        ],
        **kwargs
    )

def _java_gapic_assembly_gradle_pkg(name, assembly_name, deps, visibility = None):
    resource_target_name = "%s-resources" % assembly_name
    java_gapic_build_configs_pkg(
        name = resource_target_name,
        deps = deps,
        templates = {
            Label("//rules_gapic/java:resources/gradle/assembly.gradle.tmpl"): "build.gradle",
            Label("//rules_gapic/java:resources/gradle/settings.gradle.tmpl"): "settings.gradle",
        },
    )

    pkg_tar(
        name = name,
        extension = "tar.gz",
        deps = [
            Label("//rules_gapic/java:gradlew"),
            resource_target_name,
        ] + deps,
        package_dir = assembly_name,
        visibility = visibility,
    )

def _construct_extra_deps(scope_to_deps, versions_map):
    label_name_to_maven_artifact = {
        "policy_proto": "maven.com_google_api_grpc_proto_google_iam_v1",
        "iam_policy_proto": "maven.com_google_api_grpc_proto_google_iam_v1",
        "iam_java_proto": "maven.com_google_api_grpc_proto_google_iam_v1",
        "iam_java_grpc": "maven.com_google_api_grpc_grpc_google_iam_v1",
        "iam_policy_java_grpc": "maven.com_google_api_grpc_grpc_google_iam_v1",
    }
    extra_deps = {}
    for scope, deps in scope_to_deps.items():
        for dep in deps:
            pkg_dependency = _get_gapic_pkg_dependency_name(dep)
            if pkg_dependency:
                key = "{{%s}}" % pkg_dependency
                if not extra_deps.get(key):
                    extra_deps[key] = "%s project(':%s')" % (scope, pkg_dependency)
            elif _is_java_dependency(dep):
                for f in dep[JavaInfo].transitive_deps.to_list():
                    maven_artifact = label_name_to_maven_artifact.get(f.owner.name)
                    if not maven_artifact:
                        continue
                    key = "{{%s}}" % maven_artifact
                    if not extra_deps.get(key):
                        extra_deps[key] = "%s '%s'" % (scope, versions_map[key])

    return "\n  ".join(extra_deps.values())

def _is_java_dependency(dep):
    return JavaInfo in dep

def _is_source_dependency(dep):
    return _is_java_dependency(dep) and hasattr(dep[JavaInfo], "source_jars") and dep.label.package != "jar"

def _is_proto_dependency(dep):
    return ProtoInfo in dep

def _get_gapic_pkg_dependency_name(dep):
    files_list = dep.files.to_list()
    if not files_list or len(files_list) != 1:
        return None
    for ext in (".tar.gz", ".gz", ".tgz"):
        if files_list[0].basename.endswith(ext):
            return files_list[0].basename[:-len(ext)]
    return None
