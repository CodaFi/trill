//
//  ColoredStream.swift
//  Trill
//
//  Created by Harlan Haskins on 12/30/16.
//  Copyright © 2016 Harlan. All rights reserved.
//

import Foundation

protocol ColoredStream: TextOutputStream {
    mutating func write(_ string: String, with: [ANSIColor])
}

extension ColoredStream {
    mutating func write(_ string: String) {
        write(string, with: [])
    }
}

class ColoredANSIStream<StreamTy: TextOutputStream>: ColoredStream {

    typealias StreamType = StreamTy

    var currentColors = [ANSIColor]()
    var stream: StreamType
    let colored: Bool
    
    init(_ stream: inout StreamType, colored: Bool = true) {
        self.stream = stream
        self.colored = colored
    }
    
    required init(_ stream: inout StreamType) {
        self.stream = stream
        self.colored = true
    }
    
    func addColor(_ color: ANSIColor) {
        guard colored else { return }
        stream.write(color.rawValue)
        currentColors.append(color)
    }
    
    func reset() {
        if currentColors.isEmpty { return }
        stream.write(ANSIColor.reset.rawValue)
        currentColors = []
    }
    
    func setColors(_ colors: [ANSIColor]) {
        guard colored else { return }
        reset()
        for color in colors {
            stream.write(color.rawValue)
        }
        currentColors = colors
    }
    
    func write(_ string: String) {
        stream.write(string)
    }
    
    func write(_ string: String, with colors: [ANSIColor]) {
        self.setColors(colors)
        write(string)
        self.reset()
    }
}
