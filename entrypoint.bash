#!/usr/bin/env bash

set -x
set -eEuo pipefail

readonly supportedFileExtension='jpg,jpeg,png'
readonly modelfmt="realesrgan-x%dplus-anime"
binary=''
input=''
output=''
targetWidth=3840
targetHeight=2160
resolution=''
onePassScale=4
model=$(printf ${modelfmt} ${onePassScale})

usage() {
    echo "
Usage:

    ${0} --binary ~/.bin/realesrgan-ncnn-vulkan --input ./input --output ./output
        -b|--binary     the binary of the upscaler
        -i|--input      the folder of input images
        -o|--output     the folder to store the output images
        -r|--resolution target enlargement resolution, for example: 3840x2160

" >&2
    exit 1
}

getInput() {
    ## Parse input
    GETOPT=$(getopt \
        -o b:i:o:r: \
        --long binary:,input:,output:,resolution: \
        -- "$@")

    eval set -- "${GETOPT}"

    while true; do
        case "$1" in
        -b | --binary)
            binary=$2
            shift 2
            ;;
        -i | --input)
            input=$2
            shift 2
            ;;
        -o | --output)
            output=$2
            shift 2
            ;;
        -r | --resolution)
            resolution=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            error "Unable to parse arguments"
            usage
            exit 1
            ;;
        esac
    done
}

parseInput() {
    if [ -z "${resolution}" ]; then
        return
    fi
    IFS='x' read -ra wh <<< "${resolution}"
    local len="${#wh[@]}"
    if [ ${len} -lt 2 ]; then
        echo "${resolution} is an invalid resolution"
        exit 1 
    fi
    local width=${wh[0]}
    local height=${wh[1]}
    re='^[0-9]+$'
    if ! [[ ${width} =~ ${re} ]] || ! [[ ${height} =~ ${re} ]]; then
        echo "${resolution} is an invalid resolution"
        exit 1
    fi
    targetWidth=${width}
    targetHeight=${height}
}

getImgs() {
    imgs_in=($(ls -d ${input%/}/*))
}

ifToSkip() {
    local img=$1
    local width=$2
    local height=$3
    #check if img path is empty
    if [ -z "${img}" ]; then
        echo true
        return
    fi
    #check if img already processed
    local fullfilename=$(basename ${img})
    local filename=${fullfilename%.*}
    if [ -f ${output%/}/${filename}* ]; then
        echo true
        return
    fi
    echo false
    return
}

upscale() {
    mkdir -p "${output%/}"
    i=0
    for img in "${imgs_in[@]}"
    do
        i=$((i+1))
        ## debug code
        echo "img path: ${img}"
        echo "image #${i}: ${img}, dimensions: \"$(identify -format '%wx%h' ${img})\""
        local width=$(identify -format '%w' ${img})
        local height=$(identify -format '%h' ${img})
        toSkip=$(ifToSkip ${img} ${width} ${height})
        if [ ${toSkip} = true ]; then
            continue
        fi
        pass=$(calculateNumOfPass ${width} ${height})
        img=$(runRealesrgan ${img} ${pass})
        if [ -z "${img}" ]; then
            continue
        fi
        downscaleone ${img}
    done
}

divideAndRoundUp() {
    local x=$1
    local y=$2
    echo $(python3 -c "import math; x=${x}; y=${y}; z=x/y; print(int(math.ceil(z)))")
}

calculateNumOfPass() {
    local width=$1
    local height=$2
    #plus 0.5 at the end for always rounding up
    local scaleW=$(divideAndRoundUp ${targetWidth} ${width})
    local scaleH=$(divideAndRoundUp ${targetHeight} ${height})
    # debug
    # echo "scaleW: ${scaleW}, scaleH: ${scaleH}"
    local scale
    if [ ${scaleW} -gt ${scaleH} ]; then
        scale=${scaleW}
    else
        scale=${scaleH}
    fi
    if [ ${scale} -le 1 ]; then
        echo 0
        return
    fi
    # debug
    # echo "scale: ${scale}"
    local pass=$(divideAndRoundUp ${scale} ${onePassScale})
    # debug
    # echo "pass: ${pass}"
    echo ${pass}
}

runRealesrgan() {
    local img=$1
    local pass=$2
    local fullfilename=$(basename ${img})
    local filename=${fullfilename%.*}
    if [ ${pass} -eq 0 ]; then
        #just copy
        local cpres=$(cp ${img} "${output%/}/${fullfilename}")
        return
    fi
    i=1
    while [ ${i} -le ${pass} ]
    do
        local scalefactor=$(awk "BEGIN {x=${onePassScale}; y=${i}; z=x^y; print z}")
        local signature=$(printf ${modelfmt} ${scalefactor})
        local outputfilename="${output%/}/${filename}_${signature}.png"
        imgOrig=${img}
        execRealesrgan=$("${binary}" -i "${img}" -o "${outputfilename}" -n "${model}")
        img=${outputfilename}
        if [ ${i} -gt 1 ]; then
            #not to remove image from the input directory
            rm ${imgOrig}
        fi
        i=$((i+1))
    done
    #return output file
    echo ${img}
}

# downscale() {
#     imgs_out=($(ls -d ${output%/}/*))
#     for img in "${imgs_out[@]}"
#     do
#         downscaleone ${img}
#     done
# }

downscaleone() {
    local img=$1
    local width=$(identify -format '%w' ${img})
    local height=$(identify -format '%h' ${img})
    local scaleW=$(awk "BEGIN {x=${targetWidth}; y=${width}; z=x/y; print z*100.0}")
    local scaleH=$(awk "BEGIN {x=${targetHeight}; y=${height}; z=x/y; print z*100.0}")
    local scale
    local isScaleWGreater=$(awk "BEGIN {x=${scaleW}; y=${scaleH}; print(x>y) }")
    if [ ${isScaleWGreater} -eq 1 ]; then
        scale=${scaleW}
    else
        scale=${scaleH}
    fi
    runConvert ${img} ${scale}
}

runConvert() {
    local img=$1
    local scale=$2
    local fullfilename=$(basename ${img})
    local filename=${fullfilename%.*}
    local suffix="${fullfilename##*.}"
    convert -resize "${scale}%" "${img}" "${output%/}/${filename}_targeting_${targetWidth}x${targetHeight}.${suffix}"
    rm ${img}
}

main() {
    getImgs
    upscale
}

getInput "$@"
parseInput
main