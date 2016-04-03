#!/bin/bash

if [ ! -e "/var/run/docker.sock" ]; then
    echo "=> Cannot find docker socket(/var/run/docker.sock), please check the command!"
    exit 1
fi

if docker version >/dev/null; then
    echo "docker is running properly"
else
    echo "Cannot run docker binary at /usr/bin/docker"
    echo "Please check if the docker binary is mounted correctly"
    exit 1
fi


if [ "${CLEAN_PERIOD}" == "**None**" ]; then
    echo "=> CLEAN_PERIOD not defined, use the default value."
    CLEAN_PERIOD=1800
fi

if [ "${DELAY_TIME}" == "**None**" ]; then
    echo "=> DELAY_TIME not defined, use the default value."
    DELAY_TIME=1800
fi

if [ "${KEEP_IMAGES}" == "**None**" ]; then
    unset KEEP_IMAGES
fi

arr_keep_containers=""
if [ "${KEEP_CONTAINERS}" != "**None**" ]; then
  arr_keep_containers=$(echo ${KEEP_CONTAINERS} | tr "," "\n")
fi
unset KEEP_CONTAINERS


if [ "${LOOP}" != "false" ]; then
    LOOP=true
fi

echo "=> Run the clean script every ${CLEAN_PERIOD} seconds and delay ${DELAY_TIME} seconds to clean."

trap '{ echo "User Interupt."; exit 1; }' SIGINT
trap '{ echo "SIGTERM received, exiting."; exit 0; }' SIGTERM
while [ 1 ]
do
    # Cleanup unused volumes
    /docker-cleanup-volumes.sh

    # Cleanup exited/dead containers
    EXITED_CONTAINERS_IDS="`docker ps -a -q -f status=exited -f status=dead | xargs echo`"
    for CONTAINER_ID in $EXITED_CONTAINERS_IDS; do
      CONTAINER_IMAGE=$(docker inspect --format='{{(index .Config.Image)}}' $CONTAINER_ID)
      if [[ ! "${arr_keep_containers[@]}" =~ "${CONTAINER_IMAGE}" ]]; then
        echo "Removing container $CONTAINER_ID"
        docker rm -v $CONTAINER_ID
      fi
    done
    unset CONTAINER_ID

    # Get all containers in "created" state
    rm -f CreatedContainerIdList
    docker ps -a -q -f status=created | sort > CreatedContainerIdList

    # Get all image ID
    ALL_LAYER_NUM=$(docker images -a | tail -n +2 | wc -l)
    docker images -q --no-trunc | sort -o ImageIdList
    CONTAINER_ID_LIST=$(docker ps -aq --no-trunc)
    IFS='
    '
    # Get Image ID that is used by a containter
    rm -f ContainerImageIdList
    touch ContainerImageIdList
    for CONTAINER_ID in ${CONTAINER_ID_LIST}; do
        LINE=$(docker inspect ${CONTAINER_ID} | grep "\"Image\": \"\(sha256:\)\?[0-9a-fA-F]\{64\}\"")
        IMAGE_ID=$(echo ${LINE} | awk -F '"' '{print $4}')
        echo "${IMAGE_ID}" >> ContainerImageIdList
    done
    sort ContainerImageIdList -o ContainerImageIdList

    # Remove the images being used by cotnainers from the delete list
    comm -23 ImageIdList ContainerImageIdList > ToBeCleanedImageIdList

    # Remove those reserved images from the delete list
    if [ -n "${KEEP_IMAGES}" ]; then
        rm -f KeepImageIdList
        touch KeepImageIdList
        arr=$(echo ${KEEP_IMAGES} | tr "," "\n")
        for x in $arr
        do
            docker inspect $x | grep "\"Id\": \"\(sha256:\)\?[0-9a-fA-F]\{64\}\"" | head -1 | awk -F '"' '{print $4}'  >> KeepImageIdList
        done
        sort KeepImageIdList -o KeepImageIdList
        comm -23 ToBeCleanedImageIdList KeepImageIdList > ToBeCleanedImageIdList2
        mv ToBeCleanedImageIdList2 ToBeCleanedImageIdList
    fi

    # Wait before cleaning containers and images
    echo "=> Waiting ${DELAY_TIME} seconds before cleaning"
    sleep ${DELAY_TIME} & wait

    # Remove created containers that haven't managed to start within the DELAY_TIME interval
    rm -f CreatedContainerToClean
    comm -12 CreatedContainerIdList <(docker ps -a -q -f status=created | sort) > CreatedContainerToClean
    if [ -s CreatedContainerToClean ]; then
        while read CONTAINER_ID; do
          CONTAINER_IMAGE=$(docker inspect --format='{{(index .Config.Image)}}' $CONTAINER_ID)
          if [[ ! "${arr_keep_containers[@]}" =~ "${CONTAINER_IMAGE}" ]]; then
            echo "Removing created/stuck container $CONTAINER_ID"
            docker rm -v $CONTAINER_ID
          fi
        done <CreatedContainerToClean
    fi

    # Remove images being used by containers from the delete list again. This prevents the images being pulled from deleting
    CONTAINER_ID_LIST=$(docker ps -aq --no-trunc)
    rm -f ContainerImageIdList
    touch ContainerImageIdList
    for CONTAINER_ID in ${CONTAINER_ID_LIST}; do
        LINE=$(docker inspect ${CONTAINER_ID} | grep "\"Image\": \"\(sha256:\)\?[0-9a-fA-F]\{64\}\"")
        IMAGE_ID=$(echo ${LINE} | awk -F '"' '{print $4}')
        echo "${IMAGE_ID}" >> ContainerImageIdList
    done
    sort ContainerImageIdList -o ContainerImageIdList
    comm -23 ToBeCleanedImageIdList ContainerImageIdList > ToBeCleaned

    # Remove Images
    if [ -s ToBeCleaned ]; then
        echo "=> Start to clean $(cat ToBeCleaned | wc -l) images"
        docker rmi $(cat ToBeCleaned) 2>/dev/null
        (( DIFF_LAYER=${ALL_LAYER_NUM}- $(docker images -a | tail -n +2 | wc -l) ))
        (( DIFF_IMG=$(cat ImageIdList | wc -l) - $(docker images | tail -n +2 | wc -l) ))
        if [ ! ${DIFF_LAYER} -gt 0 ]; then
                DIFF_LAYER=0
        fi
        if [ ! ${DIFF_IMG} -gt 0 ]; then
                DIFF_IMG=0
        fi
        echo "=> Done! ${DIFF_IMG} images and ${DIFF_LAYER} layers have been cleaned."
    else
        echo "No images need to be cleaned"
    fi

    rm -f ToBeCleanedImageIdList ContainerImageIdList ToBeCleaned ImageIdList KeepImageIdList

    # Run forever or exit after the first run depending on the value of $LOOP
    [ "${LOOP}" == "true" ] || break

    echo "=> Next clean will be started in ${CLEAN_PERIOD} seconds"
    sleep ${CLEAN_PERIOD} & wait
done
