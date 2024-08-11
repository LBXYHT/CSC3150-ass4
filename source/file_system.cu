
#include "file_system.h"
#include <cuda.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>

__device__ __managed__ u32 create_time = 0;
__device__ __managed__ u32 modified_time = 0;

//init volumn superblock
__device__ void init_superblock(FileSystem *fs) {
  for (int i = 0; i < fs->SUPERBLOCK_SIZE; i++) {
    fs->volume[i] = 0;
  } 
}

//init file-control block 32kb
__device__ void init_FCB(FileSystem *fs) {
  for (int i = 0; i < fs->FCB_ENTRIES; i++) {
    fs->volume[i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE] = '\0';
  }
}


__device__ void fs_init(FileSystem *fs, uchar *volume, int SUPERBLOCK_SIZE,
							int FCB_SIZE, int FCB_ENTRIES, int VOLUME_SIZE,
							int STORAGE_BLOCK_SIZE, int MAX_FILENAME_SIZE, 
							int MAX_FILE_NUM, int MAX_FILE_SIZE, int FILE_BASE_ADDRESS)
{
  // init variables
  fs->volume = volume;

  // init constants
  fs->SUPERBLOCK_SIZE = SUPERBLOCK_SIZE;
  fs->FCB_SIZE = FCB_SIZE;
  fs->FCB_ENTRIES = FCB_ENTRIES;
  fs->STORAGE_SIZE = VOLUME_SIZE;
  fs->STORAGE_BLOCK_SIZE = STORAGE_BLOCK_SIZE;
  fs->MAX_FILENAME_SIZE = MAX_FILENAME_SIZE;
  fs->MAX_FILE_NUM = MAX_FILE_NUM;
  fs->MAX_FILE_SIZE = MAX_FILE_SIZE;
  fs->FILE_BASE_ADDRESS = FILE_BASE_ADDRESS;
  fs->FILE_ADDING_ADDRESS = FILE_BASE_ADDRESS;


  //init 
  init_superblock(fs);

  //init
  init_FCB(fs);
}


__device__ bool compare_file_name(char *filename, char *searchname) {
  bool check = true;
  for (int i = 0; i < 20; i++) {
    if (*filename != *searchname) {
      check = false;
      break;
    }
    filename++;
    searchname++;
  }
  return check;
}

__device__ u32 fs_open(FileSystem *fs, char *s, int op)
{
	/* Implement open operation here */ 
  
  u32 file_pointer = -1;
  for (int i = 0; i < fs->FCB_ENTRIES; i++) {
    u32 addr_entry = i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
    if (fs->volume[addr_entry] != '\0') {
      bool check_similarity = compare_file_name(s, (char*) &fs->volume[addr_entry]);
      if (check_similarity) {
        file_pointer = i;
        break;
      } 
    } 
  }

  if (file_pointer != -1) {
    //update modified time
    modified_time++;
    fs->volume[file_pointer * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + 22] = modified_time / 256;
    fs->volume[file_pointer * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + 23] = modified_time % 256;
    return file_pointer;
  } else {
    if (op == G_WRITE) {
      for (int i = 0; i < fs->FCB_ENTRIES; i++) {
        int temp_entry = i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
        if (fs->volume[temp_entry] == '\0') {
          file_pointer = i;
          break;
        }
      }

      int length = 0;
      int file_entry = file_pointer * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
      while (s[length] != '\0') {
        fs->volume[file_entry + length] = s[length];
        length++;
        if (length == fs->MAX_FILENAME_SIZE) {
          printf("filename length exceeds max size.");
          break;
        }
      }
      fs->volume[file_entry + length] = '\0';

      /*
      index: 
      0-19 filename
      20-21 create_time
      22-23 modified_time
      24-27 size
      28-29 address
      */

      //set create_time
      fs->volume[file_entry + 20] = create_time / 256;
      fs->volume[file_entry + 21] = create_time % 256;
      create_time++;
  
      //set modified_time
      fs->volume[file_entry + 22] = modified_time / 256;
      fs->volume[file_entry + 23] = modified_time % 256;
      modified_time++;
      
      //set size
      u32 size = 0;
      fs->volume[file_entry + 24] = size % 256;
      fs->volume[file_entry + 25] = (size>>8) % 256;
      fs->volume[file_entry + 26] = (size>>16) % 256;
      fs->volume[file_entry + 27] = (size>>24) % 256;
      //set address
      fs->volume[file_entry + 28] = fs->FILE_ADDING_ADDRESS / 256;
      fs->volume[file_entry + 29] = fs->FILE_ADDING_ADDRESS % 256;
      
      return file_pointer;
    } 
  } 
}


__device__ void fs_read(FileSystem *fs, uchar *output, u32 size, u32 fp)
{
	/* Implement read operation here */ 
  if (fp != -1 && fs->volume[fp * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE] != '\0') {
    u32 addr_entry = fs->volume[fp * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + 28] * 256 + fs->volume[fp * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + 29];
    for (int i = 0; i < size; i++) {
      output[i] = fs->volume[addr_entry + i];
    }
  }
}

__device__ u32 fs_write(FileSystem *fs, uchar* input, u32 size, u32 fp)
{
	/* Implement write operation here */  
  u32 addr_entry = fp * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
  u32 file_pointer = fs->volume[addr_entry + 28] * 256 + fs->volume[addr_entry + 29];
  u32 old_size = fs->volume[addr_entry + 24] + fs->volume[addr_entry + 25]<<8 + fs->volume[addr_entry + 26]<<16 + fs->volume[addr_entry + 27]<<24;
  //set new size
  fs->volume[addr_entry + 24] = size % 256;
  fs->volume[addr_entry + 25] = (size>>8) % 256;
  fs->volume[addr_entry + 26] = (size>>16) % 256;
  fs->volume[addr_entry + 27] = (size>>24) % 256;

  //file is empty, directly write in data
  if (fs->FILE_ADDING_ADDRESS == fs->FILE_BASE_ADDRESS) {
    for (int i = 0; i < size; i++) {
      fs->volume[file_pointer + i] = input[i];
    }
    fs->FILE_ADDING_ADDRESS += size;
  } else if (fs->FILE_ADDING_ADDRESS == fp * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + old_size) {
    for (int i = 0; i < size; i++) {
      fs->volume[file_pointer + i] = input[i];
    }
    if (size < old_size) {
      for (int i = file_pointer + old_size-size; i < file_pointer + old_size; i++) {
        fs->volume[i] = '\0';
      }
    } 
    
    fs->FILE_ADDING_ADDRESS = fs->FILE_ADDING_ADDRESS-old_size + size;
  } else {
    u32 new_addr = fs->FILE_ADDING_ADDRESS-old_size;
    u32 i = file_pointer;
    while (i < new_addr) {
      fs->volume[i] = fs->volume[i + old_size];
      i++;
    }
    for (int j = 0; j < size; j++) {
      fs->volume[new_addr + j] = input[j];
    }

    if (size < old_size) {
      for (int k = 0; k < old_size-size; k++) {
        fs->volume[fs->FILE_ADDING_ADDRESS-k] = '\0';
      }
    }
    for (int i = 0; i < fs->FCB_ENTRIES; i++) {
      u32 FCB_start = i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
      u32 addr = fs->volume[FCB_start + 28] * 256 + fs->volume[FCB_start + 29]-old_size;
      if (i != addr_entry && addr >= file_pointer) {
        if (fs->volume[FCB_start] != '\0') {
          fs->volume[FCB_start + 28] = addr / 256;
          fs->volume[FCB_start + 29] = addr % 256;
        }
      }
    }
    fs->volume[addr_entry + 28] = new_addr / 256;
    fs->volume[addr_entry + 29] = new_addr % 256;

    fs->FILE_ADDING_ADDRESS = new_addr + size;
  }
  
}

__device__ void fs_gsys(FileSystem *fs, int op) 
{
	/* Implement LS_D and LS_S operation here */  
  if (op == LS_D) {
    printf("===sort by modified time===\n");
    int temp_fcb[32];
    for (int i = 1; i < fs->FCB_ENTRIES; i++) {
      u32 addr_entry = i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
      if (fs->volume[addr_entry] != '\0') {
        int current_modified_time = fs->volume[addr_entry + 22] * 256 + fs->volume[addr_entry + 23];
        int index = i;
        for (int j = i-1; j >= 0; j--) {
          u32 addr_entry2 = j * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
          if (fs->volume[addr_entry2] != '\0') {
            int previous_modified_time = fs->volume[addr_entry2 + 22] * 256 + fs->volume[addr_entry2 + 23];
            if (previous_modified_time < current_modified_time) {
              for (int k = 0; k < fs->FCB_SIZE; k++) {
                temp_fcb[k] = fs->volume[index * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + k];
                fs->volume[index * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + k] = fs->volume[addr_entry2 + k];
                fs->volume[addr_entry2 + k] = temp_fcb[k];
              }
              index--;
            } 
          }
        }
      }
    }

    for (int i = 0; i < fs->FCB_ENTRIES; i++) {
      u32 addr_entry = i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
      if (fs->volume[addr_entry] != '\0') {
        char* head = (char*) &fs->volume[addr_entry];
        printf("%s", head);        
        printf("\n");
      }
    }
    
  } else if (op == LS_S) {
    printf("===sort by file size===\n");
    int temp_fcb[32];
    for (int i = 1; i < fs->FCB_ENTRIES; i++) {
      u32 addr_entry = i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
      if (fs->volume[addr_entry] != '\0') {
        int current_file_size = fs->volume[addr_entry + 24] + (fs->volume[addr_entry + 25]<<8) + (fs->volume[addr_entry + 26]<<16) + (fs->volume[addr_entry + 27]<<24);
        int current_create_time = fs->volume[addr_entry + 20] * 256 + fs->volume[addr_entry + 21];
        int index = i;
        for (int j = i-1; j >= 0; j--) {
          u32 addr_entry2 = j * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
          if (fs->volume[addr_entry2] != '\0') {
            int previous_file_size = fs->volume[addr_entry2 + 24] + (fs->volume[addr_entry2 + 25]<<8) + (fs->volume[addr_entry2 + 26]<<16) + (fs->volume[addr_entry2 + 27]<<24);
            int previous_create_time = fs->volume[addr_entry2 + 20] * 256 + fs->volume[addr_entry2 + 21];
            if (previous_file_size < current_file_size || (previous_file_size == current_file_size && current_create_time < previous_create_time)) {
              for (int k = 0; k < fs->FCB_SIZE; k++) {
                temp_fcb[k] = fs->volume[index * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + k];
                fs->volume[index * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE + k] = fs->volume[addr_entry2 + k];
                fs->volume[addr_entry2 + k] = temp_fcb[k];
              }
              index--;
            }
          }
        }
      }
    }
    
    for (int i = 0; i < fs->FCB_ENTRIES; i++) {
      u32 addr_entry = i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
      if (fs->volume[addr_entry] != '\0') {
        char* head = (char*) &fs->volume[addr_entry];
        u32 file_size = fs->volume[addr_entry + 24] + (fs->volume[addr_entry + 25]<<8) + (fs->volume[addr_entry + 26]<<16) + (fs->volume[addr_entry + 27]<<24);
        printf("%s", head);
        printf(" %d\n", file_size);
      }
    }
  }
}

__device__ void fs_gsys(FileSystem *fs, int op, char *s)
{
	/* Implement rm operation here */ 
  if (op == RM) {
    //check whether the file exists
    u32 file_pointer = -1;
    for (int i = 0; i < fs->FCB_ENTRIES; i++) {
      u32 addr_entry = i * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
      if (fs->volume[addr_entry] != '\0') {
        bool check_similarity = compare_file_name(s, (char*) &fs->volume[addr_entry]);
        if (check_similarity) {
          file_pointer = i;
          break;
        } 
      } 
    }

    u32 addr_entry = file_pointer * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
    if (file_pointer == -1) {
      printf("File %s does not exist!\n", s);
    } else {
      //clean the content
      u32 addr = fs->volume[addr_entry + 28] * 256 + fs->volume[addr_entry + 29];
      u32 file_size = fs->volume[addr_entry + 24] + fs->volume[addr_entry + 25]<<8 + fs->volume[addr_entry + 26]<<16 + fs->volume[addr_entry + 27]<<24;
      for (u32 i = addr; i < fs->FILE_ADDING_ADDRESS; i++) {
        if (i < fs->FILE_ADDING_ADDRESS-file_size) {
          fs->volume[i] = fs->volume[i + file_size];
        } else if (i >= fs->FILE_ADDING_ADDRESS-file_size && i < fs->FILE_ADDING_ADDRESS) {
          fs->volume[i] = '\0';
        }
      }

      fs->FILE_ADDING_ADDRESS -= file_size;
      for (int k = 0; k < fs->FCB_ENTRIES; k++) {
        u32 addr_entry2 = k * fs->FCB_SIZE + fs->SUPERBLOCK_SIZE;
        u32 new_addr = fs->volume[addr_entry2 + 28] * 256 + fs->volume[addr_entry2 + 29];
        if (fs->volume[addr_entry2] != '\0' && addr_entry2 != addr_entry) {
          if (new_addr-addr >= file_size) {
            fs->volume[addr_entry2 + 28] = (new_addr-file_size) / 256;
            fs->volume[addr_entry2 + 29] = (new_addr-file_size) % 256;
          }
        }
      }
      for (int i = 0; i < fs->FCB_SIZE; i++) {
        fs->volume[addr_entry + i] = '\0';
      }
    }
  } else {
    printf("No such operation %d\n", op);
  }
}

