#! /bin/bash

set -e
NEWLINE=$'\n'

function clone_repo() {
    SCRATCH_OWNER=modular-magician
    UPSTREAM_BRANCH=$BASE_BRANCH
    if [ "$REPO" == "terraform" ]; then
        if [ "$VERSION" == "ga" ]; then
            UPSTREAM_OWNER=hashicorp
            GH_REPO=terraform-provider-google
            LOCAL_PATH=$GOPATH/src/github.com/hashicorp/terraform-provider-google
        elif [ "$VERSION" == "beta" ]; then
            UPSTREAM_OWNER=hashicorp
            GH_REPO=terraform-provider-google-beta
            LOCAL_PATH=$GOPATH/src/github.com/hashicorp/terraform-provider-google-beta
        else
            echo "Unrecognized version $VERSION"
            exit 1
        fi
    elif [ "$REPO" == "tf-conversion" ]; then
        # This is here for backwards compatibility and can be removed after Nov 15 2021
        UPSTREAM_OWNER=GoogleCloudPlatform
        GH_REPO=terraform-google-conversion
        LOCAL_PATH=$GOPATH/src/github.com/GoogleCloudPlatform/terraform-google-conversion
    elif [ "$REPO" == "terraform-google-conversion" ]; then
        UPSTREAM_OWNER=GoogleCloudPlatform
        GH_REPO=terraform-google-conversion
        LOCAL_PATH=$GOPATH/src/github.com/GoogleCloudPlatform/terraform-google-conversion
    elif [ "$REPO" == "tf-oics" ]; then
        if [ "$UPSTREAM_BRANCH" == "main" ]; then
            UPSTREAM_BRANCH=master
        fi
        UPSTREAM_OWNER=terraform-google-modules
        GH_REPO=docs-examples
        LOCAL_PATH=$GOPATH/src/github.com/terraform-google-modules/docs-examples
    elif [ "$REPO" == "tf-cloud-docs" ]; then
        # backwards-compatability
        echo "$REPO is no longer available."
        exit 0
    else
        echo "Unrecognized repo $REPO"
        exit 1
    fi

    GITHUB_PATH=https://modular-magician:$GITHUB_TOKEN@github.com/$UPSTREAM_OWNER/$GH_REPO
    SCRATCH_PATH=https://modular-magician:$GITHUB_TOKEN@github.com/$SCRATCH_OWNER/$GH_REPO
    mkdir -p "$(dirname $LOCAL_PATH)"

    echo "BASE_BRANCH: $BASE_BRANCH"
    git clone $GITHUB_PATH $LOCAL_PATH --branch $UPSTREAM_BRANCH
}

if [ $# -lt 4 ]; then
    echo "Usage: $0 (build|diff|downstream) (terraform) (ga|beta) (pr number|sha)"
    exit 1
fi
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Did not provide GITHUB_TOKEN environment variable."
    exit 1
fi


COMMAND=$1
REPO=$2
VERSION=$3
REFERENCE=$4

mkdir ../mm-$REPO-$VERSION-$COMMAND
cp -rp ./. ../mm-$REPO-$VERSION-$COMMAND
pushd ../mm-$REPO-$VERSION-$COMMAND

# for backwards-compatibility
if [ -z "$BASE_BRANCH" ]; then
    BASE_BRANCH=main
fi


clone_repo

git config --local user.name "Modular Magician"
git config --local user.email "magic-modules@google.com"

# MMv1 now lives inside a sub-folder
pushd mmv1

if [ "$COMMAND" == "head" ]; then
    BRANCH=auto-pr-$REFERENCE
    COMMIT_MESSAGE="New generated code for MM PR $REFERENCE."
elif [ "$COMMAND" == "base" ]; then
    # In this case, there is guaranteed to be a merge commit,
    # and the *left* side of it is the old main branch.
    # the *right* side of it is the code to be merged.
    git checkout HEAD~
    BRANCH=auto-pr-$REFERENCE-old
    COMMIT_MESSAGE="Old generated code for MM PR $REFERENCE."
elif [ "$COMMAND" == "downstream" ]; then
    BRANCH=downstream-pr-$REFERENCE
    ORIGINAL_MESSAGE="$(git log -1 --pretty=%B "$REFERENCE")"
    COMMIT_MESSAGE="$ORIGINAL_MESSAGE$NEWLINE[upstream:$REFERENCE]"
fi

if [ "$REPO" == "terraform" ]; then
    pushd $LOCAL_PATH
    go mod download
    find . -type f -not -wholename "./.git*" -not -wholename "./.changelog*" -not -name ".travis.yml" -not -name ".golangci.yml" -not -name "CHANGELOG.md" -not -name "CHANGELOG_v*.md" -not -name "GNUmakefile" -not -name "docscheck.sh" -not -name "LICENSE" -not -name "README.md" -not -wholename "./examples*" -not -name ".go-version" -not -name ".hashibot.hcl" -print0 | xargs -0 git rm
    popd
fi

if [ "$REPO" == "terraform-google-conversion" ]; then
    # Generate tfplan2cai
    pushd $LOCAL_PATH
    # clear out the templates as they are copied during
    # generation from mmv1/third_party/validator/tests/data
    rm -rf ./tfplan2cai/testdata/templates/
    rm -rf ./tfplan2cai/testdata/generatedconvert/
    rm -rf ./tfplan2cai/converters/google/provider
    rm -rf ./tfplan2cai/converters/google/resources
    find ./tfplan2cai/test/** -type f -exec git rm {} \;
    popd

    bundle exec compiler.rb -a -e terraform -f validator -o $LOCAL_PATH/tfplan2cai -v $VERSION

    # Generate cai2hcl
    pushd $LOCAL_PATH
    rm -rf ./cai2hcl/*
    popd

    bundle exec compiler.rb -a -e terraform -f tgc_cai2hcl -o $LOCAL_PATH/cai2hcl -v $VERSION

    if [ "$COMMAND" == "downstream" ]; then
      pushd $LOCAL_PATH
      go get -d github.com/hashicorp/terraform-provider-google-beta@$BASE_BRANCH
      go mod tidy
      set +e
      make build
      set -e
      popd
    fi
elif [ "$REPO" == "tf-oics" ]; then
    # use terraform generator with oics override
    bundle exec compiler.rb -a -e terraform -f oics -o $LOCAL_PATH -v $VERSION
else
    if [ "$REPO" == "terraform" ]; then
        if [ "$VERSION" == "ga" ]; then
            bundle exec compiler.rb -a -e $REPO -o $LOCAL_PATH -v $VERSION --no-docs
            bundle exec compiler.rb -a -e $REPO -o $LOCAL_PATH -v beta --no-code
        else
            bundle exec compiler.rb -a -e $REPO -o $LOCAL_PATH -v $VERSION
        fi
        pushd ../
        make tpgtools OUTPUT_PATH=$LOCAL_PATH VERSION=$VERSION

        # Only generate TeamCity-related file for TPG and TPGB
        if [ "$VERSION" == "ga" ] || [ "$VERSION" == "beta" ]; then
            make teamcity-servicemap-generate OUTPUT_PATH=$LOCAL_PATH VERSION=$VERSION
        fi
        popd
    fi
fi

popd

pushd $LOCAL_PATH

git config --local user.name "Modular Magician"
git config --local user.email "magic-modules@google.com"
git add .
git checkout -b $BRANCH

COMMITTED=true
git commit --signoff -m "$COMMIT_MESSAGE" || COMMITTED=false

CHANGELOG=false
if [ "$REPO" == "terraform" ]; then
  CHANGELOG=true
fi

PR_NUMBER=$(curl -L -s -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/GoogleCloudPlatform/magic-modules/pulls?state=closed&base=$BASE_BRANCH&sort=updated&direction=desc" | \
    jq -r ".[] | if .merge_commit_sha == \"$REFERENCE\" then .number else empty end")
if [ "$COMMITTED" == "true" ] && [ "$COMMAND" == "downstream" ] && [ "$CHANGELOG" == "true" ]; then
    # Add the changelog entry!
    mkdir -p .changelog/
    curl -L -s -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/repos/GoogleCloudPlatform/magic-modules/pulls/$PR_NUMBER" | \
        jq -r .body | \
        sed -e '/```release-note/,/```/!d' \
        > .changelog/$PR_NUMBER.txt
    git add .changelog
    git commit --signoff --amend --no-edit
fi

git push $SCRATCH_PATH $BRANCH -f

if [ "$COMMITTED" == "true" ] && [ "$COMMAND" == "downstream" ]; then
    PR_BODY=$(curl -L -s -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/repos/GoogleCloudPlatform/magic-modules/pulls/$PR_NUMBER" | \
        jq -r .body)
    PR_TITLE=$(curl -L -s -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/repos/GoogleCloudPlatform/magic-modules/pulls/$PR_NUMBER" | \
        jq -r .title)
    MM_PR_URL=$(curl -L -s -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/repos/GoogleCloudPlatform/magic-modules/pulls/$PR_NUMBER" | \
        jq -r .html_url)

    echo "Base: $UPSTREAM_OWNER:$UPSTREAM_BRANCH"
    echo "Head: $SCRATCH_OWNER:$BRANCH"
    NEW_PR_URL=$(hub pull-request -b $UPSTREAM_OWNER:$UPSTREAM_BRANCH -h $SCRATCH_OWNER:$BRANCH -m "$PR_TITLE" -m "$PR_BODY" -m "Derived from $MM_PR_URL")
    if [ $? != 0 ]; then
        exit $?
    fi
    echo "Created PR $NEW_PR_URL"
    NEW_PR_NUMBER=$(echo $NEW_PR_URL | awk -F '/' '{print $NF}')

    # Wait a few seconds, then merge the PR.
    sleep 5
    echo "Merging PR $NEW_PR_URL"
    curl -L -H "Authorization: token ${GITHUB_TOKEN}" \
        -X PUT \
        -d '{"merge_method": "squash"}' \
        "https://api.github.com/repos/$UPSTREAM_OWNER/$GH_REPO/pulls/$NEW_PR_NUMBER/merge"
fi

popd
